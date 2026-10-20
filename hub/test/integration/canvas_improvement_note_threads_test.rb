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
    @path = canvas_api_improvement_notes_path(@repository.route_id, @prototype)
    @comments_path = canvas_api_review_comments_path(@repository.route_id, @prototype)
  end

  test "roundtrips prior answers and leaves a newer followup open when an older batch finishes" do
    input = note_input
    input[:status] = "sent"
    input[:thread]["originalStatus"] = "sent"
    assert_no_difference [ "Build.count", "Notification.count", "ReviewThreadRead.count" ] do
      post_note(input)
      assert_response :success
      assert_equal input[:thread], response.parsed_body.fetch("thread")

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

      input = next_revision(input)
      input[:status] = "sent"
      input[:thread]["messages"].first["status"] = "sent"
      post_note(input)
      assert_response :success
      input = next_revision(input)
      input[:status] = "ready"
      input[:thread]["messages"].first["status"] = "ready"
      input[:thread]["messages"] << copilot_message(followup["id"])
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
    assert_empty @prototype.improvement_notes.sole.replies
    assert_nil @prototype.improvement_notes.sole.build_id

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
    assert_no_difference "ReviewComment.count" do
      post_note(input)
      assert_response :success
    end
    changed = input.deep_dup
    changed[:thread]["messages"].first["body"] = "Different answer"
    post_note(changed)
    assert_response :conflict
    assert_equal input[:thread], saved.reload.note_thread
    post_note(next_revision(changed))
    assert_response :unprocessable_entity
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
      user: users.create(github_id: 1002, login: "mona"), local_id: SecureRandom.uuid,
      body: "Other author's original", note_revision: 1, note_status: "open",
      anchor: input[:anchor], note_thread: input[:thread]
    get @path, headers: @headers
    assert_equal [ own.id ], response.parsed_body.fetch("notes").pluck("id")
    assert_no_difference [ "ReviewComment.count", "Notification.count", "ReviewThreadRead.count" ] do
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
    build = builds.create_successful(prototype: @prototype)
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
    assert_nil comment.note_thread
    assert_empty comment.replies
  end

  test "thread aware deletion clears all conversation text and cannot be undone" do
    input = note_input
    input[:thread]["messages"] << copilot_message(input[:local_id])
    post_note(input)
    assert_response :success
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
  end

  private

  def post_note(input)
    post @path, params: input, headers: @headers, as: :json
  end

  def next_revision(input)
    input.deep_dup.merge(revision: input[:revision] + 1, previous_revision: input[:revision])
  end

  def author_message
    { "id" => SecureRandom.uuid, "role" => "author", "body" => "New follow-up", "status" => "open" }
  end

  def copilot_message(request_id)
    { "id" => SecureRandom.uuid, "role" => "copilot", "body" => "Saved answer", "status" => "ready", "requestIds" => [ request_id ] }
  end

  def note_input
    {
      local_id: SecureRandom.uuid, revision: 1, previous_revision: 0,
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
