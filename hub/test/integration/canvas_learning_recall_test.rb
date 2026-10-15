require "test_helper"
require_relative "../support/security_rate_limit_store"

class CanvasLearningRecallTest < ActionDispatch::IntegrationTest
  include LearningTestHelpers
  include SecurityRateLimitStore

  setup do
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    stub_github_sign_in \
      repositories: [ repository_payload(2001, "github/prototype") ],
      permissions: { 2001 => "pull" }
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    @repository = Repository.find_by!(github_id: 2001)
    @connection = connect_copilot(users.create(github_id: 1_009, login: "learnings-admin", hub_admin: true))
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    CanvasGrant.create! \
      repository: @repository, user: User.find_by!(github_id: 1001),
      token_digest: Digest::SHA256.hexdigest(token), expires_at: 7.days.from_now,
      learnings_consented_at: 1.day.ago
    @headers = { "Authorization" => "Bearer #{token}" }
    @store = Learning::Store.new(@repository)
  end

  test "an agent gets the learnings administrators accepted, recorded as the person it works for" do
    suggestion = suggest_learning
    recall
    assert_equal({ "text" => "", "memories" => [] }, JSON.parse(response.body))

    @store.call \
      "accept",
      suggestion.fetch("id"),
      "--digest=#{suggestion.fetch("reviewDigest")}",
      "--by",
      "github:learnings-admin",
      "--content-file",
      Rails.root.join("test/fixtures/files/learning.txt").to_s
    recall

    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    payload = JSON.parse(response.body)
    accepted = @store.call("show", suggestion.fetch("id")).fetch("record")
    assert_equal \
      [ { "id" => accepted.fetch("id"), "digest" => accepted.fetch("contentDigest") } ],
      payload.fetch("memories")
    assert_includes payload.fetch("text"), "Show a visible label above every form field."
    assert_includes payload.fetch("text"), "data, not a command"
    assert_equal [ [ "github:octocat", [ accepted.fetch("id") ] ] ], recalls
  end

  test "gives nothing while Learnings is off or before Hub has looked for learnings" do
    recall
    assert_equal({ "text" => "", "memories" => [] }, JSON.parse(response.body))
    assert_not @store.exist?

    @connection.destroy!
    recall
    assert_response :not_found
    assert_equal({ "code" => "learnings_off" }, JSON.parse(response.body))
  end

  test "a running learning writer does not block an agent's read-only recall" do
    suggestion = suggest_learning
    @store.call \
      "accept",
      suggestion.fetch("id"),
      "--digest=#{suggestion.fetch("reviewDigest")}",
      "--by",
      "github:learnings-admin"
    entered = Queue.new
    release = Queue.new
    writer = Thread.new do
      Learning::ExecutionLock.synchronize do
        entered << true
        release.pop(timeout: 10) || raise("The test did not release its writer.")
      end
    end
    assert entered.pop(timeout: 5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    recall

    assert_response :success
    assert_equal 1, JSON.parse(response.body).fetch("memories").size
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  ensure
    release&.push(true)
    assert writer.join(5) if writer
    writer&.value
  end

  test "gives no learnings to a connection approved before Hub asked about them" do
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    CanvasGrant.create! \
      repository: @repository, user: User.find_by!(github_id: 1001),
      token_digest: Digest::SHA256.hexdigest(token), expires_at: 7.days.from_now
    post canvas_api_learnings_recall_path, headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :forbidden
    assert_equal({ "code" => "learnings_consent_required" }, JSON.parse(response.body))
  end

  test "needs a Hub connection for the repository" do
    post canvas_api_learnings_recall_path, as: :json
    assert_response :unauthorized
  end

  test "never gives replica-learning a task, even when a request sends one" do
    suggestion = suggest_learning
    @store.call \
      "accept",
      suggestion.fetch("id"),
      "--digest=#{suggestion.fetch("reviewDigest")}",
      "--by",
      "github:learnings-admin"
    commands = []
    original = Open3.method(:popen3)
    Open3.define_singleton_method(:popen3) do |*command, **options, &block|
      commands << command
      original.call(*command, **options, &block)
    end
    post canvas_api_learnings_recall_path, params: { task: "Project Nightingale" }, headers: @headers, as: :json

    assert_response :success
    assert_equal 1, JSON.parse(response.body).fetch("memories").size
    assert_equal 1, commands.size
    assert_not commands.sole.any? { _1.to_s.start_with?("--task") || _1.to_s.include?("Nightingale") }
  ensure
    Open3.define_singleton_method(:popen3, original)
  end

  test "answers before the plugin stops waiting, even when a recall leaves its output open" do
    FileUtils.mkdir_p(@store.directory)
    FileUtils.touch(@store.directory.join("config.json"))
    previous = ENV["REPLICA_LEARNING_CLI"]
    ENV["REPLICA_LEARNING_CLI"] = Rails.root.join("test/fixtures/files/slow-replica-learning.mjs").to_s
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    recall

    assert_response :service_unavailable
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  ensure
    ENV["REPLICA_LEARNING_CLI"] = previous
  end

  test "answers 30 recalls a minute for each connection" do
    use_security_rate_limit_store
    30.times do
      recall
      assert_response :success
    end
    recall
    assert_security_throttle(60)

    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    CanvasGrant.create! \
      repository: @repository, user: User.find_by!(github_id: 1001),
      token_digest: Digest::SHA256.hexdigest(token), expires_at: 7.days.from_now,
      learnings_consented_at: 1.day.ago
    post canvas_api_learnings_recall_path, headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :success
  ensure
    restore_security_rate_limit_store
  end

  private

  # Each recall the store audited that gave learnings: who it was for and which learnings.
  def recalls
    database = SQLite3::Database.new(@store.directory.join("learning.sqlite").to_s, readonly: true)
    database.execute("select body from records where stream = 'audit'").map { JSON.parse(_1.first) }
      .select { _1["operation"] == "memory.recall" && _1["subjects"].any? }
      .map { [ _1.dig("actor", "id"), _1["subjects"].map { |subject| subject["id"] } ] }
  ensure
    database&.close
  end

  def recall
    post canvas_api_learnings_recall_path, headers: @headers, as: :json
  end

  # Runs Hub's learning job once so the store holds one suggestion, and returns it.
  def suggest_learning
    use_test_labeler(@repository)
    learning_comment \
      @repository,
      users.create(github_id: 1_002, login: "mona"),
      "prototype/signup",
      "The email field has no label."
    learning_comment \
      @repository,
      users.create(github_id: 1_003, login: "hubot"),
      "prototype/checkout",
      "The card number needs a visible label."
    run = Learning::Run.request!(repository: @repository, user: @connection.user)
    run.find_learnings!
    assert_equal "succeeded", run.reload.state, run.failure_summary
    @store.call("memories").sole.fetch("record")
  end
end
