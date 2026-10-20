require "test_helper"

class ImprovementCommentTest < ActiveSupport::TestCase
  test "the database rejects duplicate message identities within an owner's prototype" do
    root = create_note
    duplicate = root.replies.first.dup
    duplicate.position = root.replies.maximum(:position) + 1

    assert_raises(ActiveRecord::StatementInvalid) { duplicate.save!(validate: false) }
    assert_equal 2, root.replies.count
  end

  test "the database keeps answer links unique and inside their conversation" do
    root = create_note
    other = create_note(prototype: root.prototype, user: root.user)
    response = root.replies.find_by!(role: "copilot")
    link = ImprovementCommentReply.find_by!(response_id: response.id)

    assert_raises(ActiveRecord::StatementInvalid) { link.dup.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { link.update_columns(request_id: other.id) }
    assert_equal root.id, link.reload.request_id
  end

  private

  def create_note(prototype: prototypes.create, user: users.create)
    local_id = SecureRandom.uuid
    build = prototype.builds.first || builds.create_successful(prototype:)
    ImprovementComment.create! \
      prototype:, build:, user:, local_id:, note_revision: 1, note_status: "open",
      body: "Original request", anchor: valid_anchor,
      note_thread: {
        "version" => 1, "originalStatus" => "open",
        "messages" => [
          { "id" => SecureRandom.uuid, "role" => "author", "body" => "Follow-up request", "status" => "open" },
          { "id" => SecureRandom.uuid, "role" => "copilot", "body" => "Saved answer", "status" => "ready", "requestIds" => [ local_id ] }
        ]
      }
  end

  def valid_anchor
    {
      "schemaVersion" => 1, "kind" => "element",
      "route" => { "pathname" => "/", "search" => "", "hash" => "" },
      "selector" => "#save", "accessibleName" => "Save", "tagName" => "button", "selectedText" => "",
      "rect" => { "x" => 20, "y" => 30, "width" => 100, "height" => 32 },
      "viewport" => { "width" => 1280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
      "elementOffset" => { "x" => 0.5, "y" => 0.5 }
    }
  end
end
