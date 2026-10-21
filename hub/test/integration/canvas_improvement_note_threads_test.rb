require "test_helper"

class CanvasImprovementNoteThreadsTest < ActionDispatch::IntegrationTest
  setup do
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    stub_github_sign_in \
      repositories: [ repository_payload(2001, "github/prototype") ],
      permissions: { 2001 => "push" }
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    @repository = Repository.find_by!(github_id: 2001)
    @viewer = User.find_by!(github_id: 1001)
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    CanvasGrant.create! \
      repository: @repository, user: @viewer,
      token_digest: Digest::SHA256.hexdigest(token), expires_at: 7.days.from_now
    @headers = { "Authorization" => "Bearer #{token}" }
    @prototype = prototypes.create(repository: @repository)
    @build = builds.create_successful(prototype: @prototype)
    @path = canvas_api_improvement_notes_path(@repository.route_id, @prototype)
    @comments_path = canvas_api_review_comments_path(@repository.route_id, @prototype)
  end

  test "roundtrips prior answers and leaves a newer followup open when an older batch finishes" do
    input = note_input
    input[:status] = "sent"
    input[:thread]["originalStatus"] = "sent"
    assert_no_difference [ "ReviewComment.count", "Build.count", "Notification.count", "ReviewThreadRead.count", "Analytics::Event.count" ] do
      post_note(input)
      assert_response :success
      assert_equal input[:thread], response.parsed_body.fetch("thread")
      assert_equal @build.number, response.parsed_body.fetch("buildNumber")

      followup = author_message
      input = next_revision(input)
      input[:thread]["messages"] << followup
      input[:status] = "open"
      post_note(input)
      assert_response :success

      input = next_revision(input)
      input[:thread]["originalStatus"] = "ready"
      input[:thread]["messages"] << copilot_message(input[:local_id])
      post_note(input)
      assert_response :success
      assert_equal "open", response.parsed_body.fetch("status")
      assert_equal "open", response.parsed_body.fetch("thread").fetch("messages").first.fetch("status")
      saved = @prototype.improvement_notes.sole
      assert_equal "ready", saved.status
      assert_equal "open", saved.note_status

      input = next_revision(input)
      input[:status] = "sent"
      input[:thread]["messages"].first["status"] = "sent"
      post_note(input)
      assert_response :success
      input = next_revision(input)
      input[:status] = "ready"
      input[:thread]["messages"].first["status"] = "ready"
      input[:thread]["messages"] << copilot_message(input[:local_id], followup["id"])
      post_note(input)
      assert_response :success
      input = next_revision(input).merge(status: "resolved")
      post_note(input)
      assert_response :success
    end

    get @path, headers: @headers
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("threadVersion")
    assert_equal input[:thread], response.parsed_body.fetch("notes").sole.fetch("thread")
    assert_equal input[:body], response.parsed_body.fetch("notes").sole.fetch("body")
    assert_equal 1, @prototype.improvement_notes.count
    root = @prototype.improvement_notes.sole
    assert_equal @build, root.build
    messages = root.replies.index_by(&:local_id)
    assert_equal input[:thread].fetch("messages").pluck("id").sort, messages.keys.sort
    assert messages.values.all? { _1.root_id == root.id && _1.prototype_id == @prototype.id }
    assert messages.values.all? { _1.build_id.nil? }
    input[:thread].fetch("messages").each do |message|
      row = messages.fetch(message.fetch("id"))
      assert_equal message.values_at("role", "body", "status"), [ row.role, row.body, row.status ]
      next unless message.fetch("role") == "copilot"

      requests = ImprovementCommentReply.where(response_id: row.id).pluck(:request_id)
      expected = message.fetch("requestIds").map { _1 == root.local_id ? root.id : messages.fetch(_1).id }
      assert_equal expected.sort, requests.sort
    end

    [ @comments_path, canvas_api_repository_review_comments_path(@repository.route_id) ].each do |path|
      get path, headers: @headers
      assert_empty response.parsed_body.fetch("comments")
      get path, params: { improvement_notes: "include" }, headers: @headers
      assert_equal input[:thread], response.parsed_body.fetch("comments").sole.fetch("thread")
    end
    get canvas_api_repository_review_comment_summaries_path(@repository.route_id), headers: @headers
    assert_empty response.parsed_body.fetch("comments")
  end

  test "guards exact revisions stale clones original text and immutable answer history" do
    input = note_input
    input[:thread]["messages"] << copilot_message(input[:local_id])
    post_note(input)
    assert_response :success
    saved = @prototype.improvement_notes.sole
    assert_no_difference [ "ImprovementComment.count", "ImprovementCommentReply.count" ] do
      post_note(input)
      assert_response :success
    end
    changed = input.deep_dup
    changed[:thread]["messages"].first["body"] = "Different answer"
    post_note(changed)
    assert_response :conflict
    assert_equal input[:thread], saved.reload.note_thread
    rejected = next_revision(changed)
    followup = author_message
    rejected[:thread]["messages"].concat([ followup, copilot_message(followup.fetch("id")) ])
    assert_no_difference [ "ImprovementComment.count", "ImprovementCommentReply.count" ] do
      post_note(rejected)
      assert_response :unprocessable_entity
    end
    assert_equal 1, saved.reload.note_revision
    assert_equal input[:thread], saved.note_thread
    post_note(next_revision(input).merge(body: "Changed original"))
    assert_response :unprocessable_entity
    post_note(next_revision(input).merge(anchor: input[:anchor].merge("selector" => "#different")))
    assert_response :conflict

    updated = next_revision(input)
    updated[:thread]["messages"] << author_message
    post_note(updated)
    assert_response :success
    post_note(input)
    assert_response :conflict
    post_note(input.merge(revision: 5, previous_revision: 1))
    assert_response :conflict
    assert_equal updated[:thread], saved.reload.note_thread
    assert_equal 2, saved.note_revision
  end

  test "legacy writes stay compatible until a lossless upgrade and old clients then conflict" do
    input = note_input.except(:thread)
    post_note(input)
    assert_response :success
    assert_nil response.parsed_body.fetch("thread")
    input = next_revision(input).merge(body: "Legacy edited text")
    post_note(input)
    assert_response :success
    upgraded = next_revision(input).merge(thread: { "version" => 1, "originalStatus" => "open", "messages" => [] })
    post_note(upgraded.merge(body: "Changed during backfill"))
    assert_response :unprocessable_entity
    post_note(upgraded)
    assert_response :success
    assert_equal input[:body], response.parsed_body.fetch("body")

    [ upgraded.except(:thread), next_revision(upgraded).except(:thread),
      next_revision(upgraded).except(:thread).merge(deleted: true) ].each do |old_client|
      post_note(old_client)
      assert_response :conflict
      assert_match(/upgrade/i, response.parsed_body.fetch("error"))
    end
    get @path, headers: @headers
    assert_equal 2, response.parsed_body.fetch("threadVersion")
    assert_equal upgraded[:thread], response.parsed_body.fetch("notes").sole.fetch("thread")
  end

  test "rejects nonobject thread params invalid payloads and inconsistent aggregate status" do
    input = note_input
    [ nil, [], "text", 1 ].each do |thread|
      post_note(input.merge(thread:))
      assert_response :bad_request
    end
    [ {}, input[:thread].merge("version" => 3),
      input[:thread].merge("messages" => [ copilot_message(SecureRandom.uuid) ]) ].each do |thread|
      post_note(input.merge(thread:))
      assert_response :unprocessable_entity
    end
    post_note(input.merge(status: "resolved"))
    assert_response :unprocessable_entity
    post_note(input.merge(status: "ready"))
    assert_response :unprocessable_entity
    post_note(input.merge(note_thread: input[:thread]))
    assert_response :bad_request
    assert_empty @prototype.improvement_notes
  end

  test "creator collection stays private and ordinary mutation endpoints cannot change notes" do
    input = note_input
    post_note(input)
    assert_response :success
    own = @prototype.improvement_notes.sole
    other = @prototype.improvement_notes.create! \
      build: @build, user: users.create(github_id: 1002, login: "mona"), local_id: SecureRandom.uuid,
      body: "Other author's original", note_revision: 1, note_status: "open",
      anchor: input[:anchor], note_thread: input[:thread]
    get @path, headers: @headers
    assert_equal [ own.id ], response.parsed_body.fetch("notes").pluck("id")
    assert_no_difference [ "ReviewComment.count", "ImprovementComment.count", "Notification.count", "ReviewThreadRead.count" ] do
      [ own, other ].each do |note|
        patch "#{@comments_path}/#{note.id}",
          params: { review_comment: { body: "Edited via ordinary API", note_thread: nil } },
          headers: @headers, as: :json
        assert_response :not_found
        delete "#{@comments_path}/#{note.id}", headers: @headers
        assert_response :not_found
        post "#{@comments_path}/#{note.id}/replies",
          params: { review_comment: { body: "Forbidden reply" } }, headers: @headers, as: :json
        assert_response :not_found
        post "#{@comments_path}/#{note.id}/resolution", headers: @headers
        assert_response :not_found
      end
    end
    assert_equal input[:thread], own.reload.note_thread
    assert_equal input[:body], own.body
    assert_equal input[:thread], other.reload.note_thread
  end

  test "ordinary comments reject thread parameters without mutating their bodies" do
    build = @build
    comment = ReviewComment.create! \
      prototype: @prototype, build:, user: @viewer, body: "Ordinary comment", anchor: note_input[:anchor]
    [ :thread, :note_thread ].each do |field|
      post @comments_path,
        params: { review_comment: { build_number: build.number, body: "New comment", anchor: comment.anchor, field => {} } },
        headers: @headers, as: :json
      assert_response :bad_request
      patch "#{@comments_path}/#{comment.id}",
        params: { review_comment: { body: "Edited", field => {} } }, headers: @headers, as: :json
      assert_response :bad_request
      post "#{@comments_path}/#{comment.id}/replies",
        params: { review_comment: { body: "Reply", field => {} } }, headers: @headers, as: :json
      assert_response :bad_request
    end
    assert_equal "Ordinary comment", comment.reload.body
    assert_empty comment.replies
  end

  test "thread aware deletion clears all conversation text and cannot be undone" do
    input = note_input
    followup = author_message
    input[:thread]["messages"] << followup
    input[:thread]["messages"] << copilot_message(input[:local_id], followup.fetch("id"))
    post_note(input)
    assert_response :success
    root = @prototype.improvement_notes.sole
    conversation_ids = [ root.id, *root.replies.pluck(:id) ]
    assert_equal 3, conversation_ids.length
    deleted = next_revision(input).merge(deleted: true)
    post_note(deleted)
    assert_response :success
    assert_nil response.parsed_body.fetch("body")
    assert_nil response.parsed_body.fetch("thread")
    assert_not_nil response.parsed_body.fetch("deletedAt")
    post_note(deleted)
    assert_response :success
    post_note(deleted.merge(thread: {}))
    assert_response :unprocessable_entity
    post_note(next_revision(deleted).merge(deleted: false))
    assert_response :conflict
    get @path, headers: @headers
    assert_nil response.parsed_body.fetch("notes").sole.fetch("thread")
    assert_nil root.reload.body
    assert_nil root.note_thread
    assert_empty ImprovementComment.where(id: conversation_ids).where.not(body: nil)
  end

  test "all note collections paginate complete captures within the serialized response budget" do
    notes = 4.times.map do |index|
      create_note(capture: "data:image/png;base64,#{"A" * 1_400_000}#{index}")
    end
    expected = notes.index_by(&:id)
    collections = [
      [ @path, "notes", {} ],
      *[ @comments_path, canvas_api_repository_review_comments_path(@repository.route_id) ].flat_map do |path|
        %w[include only].map { [ path, "comments", { improvement_notes: _1 } ] }
      end
    ]

    collections.each do |path, key, filters|
      received = []
      cursor = nil
      completed = false
      (notes.length + 1).times do
        batches = []
        subscriber = ->(event) do
          batches << event.payload.fetch(:record_count) if event.payload[:class_name] == "ImprovementComment"
        end
        ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
          get path, params: filters.merge(cursor:).compact, headers: @headers
        end
        assert_response :success
        assert_operator response.body.bytesize, :<=, 2 * 1024 * 1024
        assert_operator batches.max || 0, :<=, 2, "must not load every large capture before selecting a page"
        page = response.parsed_body
        records = page.fetch(key)
        assert_not_empty records
        records.each do |record|
          original = expected.fetch(record.fetch("id"))
          assert_equal original.capture, record.fetch("capture")
          assert_equal original.body, record.fetch("body")
          assert_equal original.anchor, record.fetch("anchor")
          assert_equal original.note_thread, record.fetch("thread")
        end
        received.concat(records.pluck("id"))
        unless page.fetch("hasMore")
          assert_nil page.fetch("nextCursor")
          completed = true
          break
        end

        next_cursor = page.fetch("nextCursor")
        assert next_cursor.is_a?(String) && next_cursor.present?
        assert_not_equal cursor, next_cursor
        cursor = next_cursor
      end
      assert completed, "note pagination must terminate"
      assert_equal expected.keys.sort, received.sort
      assert_equal received.uniq, received, "note pages must not repeat records"
    end
  end

  test "small creator collections remain complete through the default 200 notes including tombstones" do
    notes = 200.times.map { create_note }
    notes.last.update!(body: nil, deleted_at: Time.current)
    create_note(user: users.create(github_id: 1002, login: "mona"))

    get @path, headers: @headers

    assert_response :success
    page = response.parsed_body
    assert_equal notes.map(&:id).sort, page.fetch("notes").pluck("id").sort
    tombstone = page.fetch("notes").find { _1.fetch("id") == notes.last.id }
    assert_not_nil tombstone.fetch("deletedAt")
    assert_nil tombstone.fetch("body")
    assert_nil tombstone.fetch("thread")
    assert_equal false, page.fetch("hasMore")
    assert_nil page.fetch("nextCursor")
  end

  test "creator continuation cursors cannot cross viewers prototypes or list and filter contexts" do
    2.times { create_note }
    get @path, params: { pageSize: 1 }, headers: @headers
    assert_response :success
    cursor = response.parsed_body.fetch("nextCursor")
    assert_not_nil cursor
    other_prototype = prototypes.create(repository: @repository, branch_name: "prototype/other")
    other_path = canvas_api_improvement_notes_path(@repository.route_id, other_prototype)
    get other_path, params: { cursor: }, headers: @headers
    assert_response :bad_request

    [ @comments_path, canvas_api_repository_review_comments_path(@repository.route_id) ].each do |path|
      %w[exclude include only].each do |filter|
        get path, params: { cursor:, improvement_notes: filter }, headers: @headers
        assert_response :bad_request
      end
      get path, params: { pageSize: 1, improvement_notes: "only" }, headers: @headers
      assert_response :success
      list_cursor = response.parsed_body.fetch("nextCursor")
      assert_not_nil list_cursor
      get @path, params: { cursor: list_cursor }, headers: @headers
      assert_response :bad_request
    end

    other = users.create(github_id: 1002, login: "mona")
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    CanvasGrant.create! \
      repository: @repository, user: other,
      token_digest: Digest::SHA256.hexdigest(token), expires_at: 7.days.from_now
    stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => "push" },
      github_id: other.github_id, login: other.login)
    get @path, params: { cursor: }, headers: { "Authorization" => "Bearer #{token}" }
    assert_response :bad_request
  end

  test "malformed scalar fields are rejected before existing notes can be selected or changed" do
    input = note_input
    post_note(input)
    assert_response :success
    saved = @prototype.improvement_notes.sole
    original = saved.attributes
    invalid = %i[local_id body status capture].flat_map do |field|
      [ 42, true, [], {} ].map { [ field, _1 ] }
    end
    invalid << [ :local_id, [ input[:local_id] ] ]

    assert_no_difference "ImprovementComment.count" do
      invalid.each do |field, value|
        post_note(next_revision(input).merge(field => value))
        assert_response :bad_request, "#{field} must reject #{value.inspect}"
        assert_equal original, saved.reload.attributes
      end
    end
  end

  test "note mutation capabilities require both ownership and repository write access" do
    own = create_note
    deleted = create_note
    deleted.update!(body: nil, deleted_at: Time.current)
    create_note(user: users.create(github_id: 1002, login: "mona"))
    collections = [
      [ @path, "notes", {} ],
      [ @comments_path, "comments", { improvement_notes: "include" } ],
      [ canvas_api_repository_review_comments_path(@repository.route_id), "comments", { improvement_notes: "only" } ]
    ]
    [ [ 0, true ], [ 2.minutes, false ] ].each do |elapsed, can_write|
      stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => can_write ? "push" : "pull" })
      travel elapsed do
        collections.each do |path, key, filters|
          get path, params: filters, headers: @headers
          assert_response :success
          records = response.parsed_body.fetch(key)
          assert_includes records.pluck("id"), own.id
          assert_includes records.pluck("id"), deleted.id
          records.each do |record|
            allowed = can_write && record.fetch("id") == own.id
            assert_equal allowed, record.fetch("viewerCanEdit")
            assert_equal allowed, record.fetch("viewerCanDelete")
          end
        end
      end
    end
  end

  test "first uploads retain historical owner logins after a rename and freeze both author snapshots" do
    input = note_input
    @viewer.update!(login: "mona_enterprise")
    author = { "id" => @viewer.id, "login" => @viewer.login, "avatarUrl" => nil }
    input[:thread].merge!("version" => 2, "originalAuthor" => author)
    input[:thread]["messages"] << author_message.merge("author" => author.deep_dup)
    @viewer.update!(login: "renamed-owner")
    stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => "push" },
      github_id: @viewer.github_id, login: @viewer.login)

    post_note(input)

    assert_response :success
    assert_equal input[:thread], response.parsed_body.fetch("thread")
    saved = @prototype.improvement_notes.sole
    assert_equal author, saved.note_thread.fetch("originalAuthor")
    assert_equal author, saved.note_thread.fetch("messages").sole.fetch("author")
    [
      ->(thread) { thread["originalAuthor"]["login"] = @viewer.login },
      ->(thread) { thread["messages"].first["author"]["login"] = @viewer.login },
      ->(thread) { thread["originalAuthor"]["id"] = @viewer.id + 1 }
    ].each do |change|
      updated = next_revision(input)
      change.call(updated[:thread])
      post_note(updated)
      assert_response :unprocessable_entity
      assert_equal input[:thread], saved.reload.note_thread
    end
  end

  test "renamed owners can delete version two snapshots and retry without restoring conversation text" do
    input = note_input
    author = { "id" => @viewer.id, "login" => @viewer.login, "avatarUrl" => nil }
    input[:thread].merge!("version" => 2, "originalAuthor" => author)
    input[:thread]["messages"] << author_message.merge("author" => author.deep_dup)
    post_note(input)
    assert_response :success
    saved = @prototype.improvement_notes.sole
    @viewer.update!(login: "renamed-owner")
    stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => "push" },
      github_id: @viewer.github_id, login: @viewer.login)
    deleted = next_revision(input).merge(deleted: true)
    changed_history = deleted.deep_dup
    changed_history[:thread]["messages"].first["body"] = "Rewritten history"
    post_note(changed_history)
    assert_response :unprocessable_entity
    assert_equal input[:thread], saved.reload.note_thread

    2.times do
      post_note(deleted)
      assert_response :success
      assert_nil response.parsed_body.fetch("body")
      assert_nil response.parsed_body.fetch("thread")
      assert_nil saved.reload.body
      assert_nil saved.note_thread
    end

    [
      author.merge("id" => @viewer.id + 1),
      author.merge("login" => "not a valid login"),
      author.merge("extra" => true)
    ].each do |invalid_author|
      retry_input = deleted.deep_dup
      retry_input[:thread]["originalAuthor"] = invalid_author
      post_note(retry_input)
      assert_response :unprocessable_entity
      assert_nil saved.reload.body
      assert_nil saved.note_thread
    end
  end

  private

  def create_note(**attributes)
    input = note_input
    @prototype.improvement_notes.create! \
      build: @build, user: @viewer, local_id: input[:local_id], body: input[:body], note_revision: 1,
      note_status: "open", anchor: input[:anchor], note_thread: input[:thread], **attributes
  end

  def post_note(input)
    post @path, params: input, headers: @headers, as: :json
  end

  def next_revision(input)
    input.deep_dup.merge(revision: input[:revision] + 1, previous_revision: input[:revision])
  end

  def author_message
    { "id" => SecureRandom.uuid, "role" => "author", "body" => "New follow-up", "status" => "open" }
  end

  def copilot_message(*request_ids)
    { "id" => SecureRandom.uuid, "role" => "copilot", "body" => "Saved answer", "status" => "ready", "requestIds" => request_ids }
  end

  def note_input
    {
      local_id: SecureRandom.uuid, build_number: @build.number, revision: 1, previous_revision: 0,
      body: "Read-only original", status: "open", deleted: false, capture: "",
      thread: { "version" => 1, "originalStatus" => "open", "messages" => [] },
      anchor: {
        "schemaVersion" => 1, "kind" => "element",
        "route" => { "pathname" => "/", "search" => "", "hash" => "" },
        "selector" => "#save", "accessibleName" => "Save", "tagName" => "button", "selectedText" => "",
        "rect" => { "x" => 20, "y" => 30, "width" => 100, "height" => 32 },
        "viewport" => { "width" => 1280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
        "elementOffset" => { "x" => 0.5, "y" => 0.5 }
      }
    }
  end
end
