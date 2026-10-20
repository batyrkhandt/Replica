require "test_helper"

class ReviewCommentNoteThreadTest < ActiveSupport::TestCase
  test "allows owner attribution of unknown legacy authors without changing saved request content" do
    note = build_note
    message = author_message
    note.note_thread = thread_payload(messages: [ message ])
    note.save!
    author = { "id" => note.user_id, "login" => note.user.login, "avatarUrl" => nil }
    note.note_thread["version"] = 2
    note.note_thread["originalAuthor"] = author
    note.note_thread["messages"][0]["author"] = author
    note.save!
    assert_equal message["body"], note.reload.note_thread["messages"][0]["body"]
    note.note_thread["messages"][0]["body"] = "Changed original"
    assert_not note.save
    note.reload
    note.note_thread["messages"][0].delete("author")
    assert_not note.save
  end

  test "keeps version two author snapshots immutable and rejects foreign attribution" do
    note = build_note
    author = { "id" => note.user_id, "login" => note.user.login, "avatarUrl" => "https://avatars.githubusercontent.com/u/42" }
    note.note_thread = thread_payload.merge("version" => 2, "originalAuthor" => author)
    note.save!
    note.note_thread["originalAuthor"]["avatarUrl"] = "https://avatars.githubusercontent.com/u/43"
    assert_not note.save
    note.reload
    note.note_thread["messages"] << author_message.merge("author" => author)
    note.save!
    note.note_thread["messages"][0]["author"]["id"] += 1
    assert_not note.save
    note.reload
    note.note_thread["version"] = 1
    note.note_thread.delete("originalAuthor")
    assert_not note.save
    foreign = build_note(prototype: note.prototype, user: note.user)
    foreign.note_thread = thread_payload.merge("version" => 2, "originalAuthor" => author.merge("id" => note.user_id + 1))
    assert_not foreign.valid?
  end

  test "version two snapshots accept Enterprise Managed User logins but reject foreign identities" do
    owner = users.create(login: "mona_enterprise")
    note = build_note(user: owner)
    author = { "id" => owner.id, "login" => owner.login, "avatarUrl" => nil }
    note.note_thread = thread_payload(messages: [ author_message.merge("author" => author.deep_dup) ])
      .merge("version" => 2, "originalAuthor" => author)
    note.save!
    assert_equal author, note.reload.note_thread.fetch("originalAuthor")
    assert_equal author, note.note_thread.fetch("messages").sole.fetch("author")

    [ "original", "followup" ].each do |position|
      candidate = build_note(user: owner, prototype: note.prototype)
      candidate.note_thread = thread_payload(messages: [ author_message.merge("author" => author.deep_dup) ])
        .merge("version" => 2, "originalAuthor" => author.deep_dup)
      invalid_author = author.merge("id" => owner.id + 1)
      if position == "original"
        candidate.note_thread["originalAuthor"] = invalid_author
      else
        candidate.note_thread["messages"].first["author"] = invalid_author
      end
      assert_not candidate.valid?, "#{position} must reject #{invalid_author.inspect}"
      assert_not_empty candidate.errors[:note_thread]
    end
  end

  test "legacy notes stay standalone while threaded notes derive status from all requests" do
    note = build_note
    assert note.valid?
    assert_nil note.note_thread
    note.note_thread = thread_payload

    %w[open sent blocked ready].each do |status|
      note.note_thread["originalStatus"] = status
      note.note_status = status
      assert note.valid?, note.errors.full_messages.inspect
    end
    note.note_status = "resolved"
    assert note.valid?
    note.note_thread["originalStatus"] = "open"
    assert_not note.valid?
    note.note_thread["originalStatus"] = "resolved"
    assert_not note.valid?

    %w[open sent blocked ready].repeated_permutation(2) do |original, followup|
      note.note_thread = thread_payload(original:, messages: [ author_message(status: followup) ])
      expected = %w[open sent blocked ready].find { [ original, followup ].include?(_1) }
      note.note_status = expected
      assert note.valid?, "#{original}/#{followup}: #{note.errors.full_messages}"
      note.note_status = (expected == "ready" ? "blocked" : "ready")
      assert_not note.valid?
    end
  end

  test "rejects malformed shapes statuses identities and request references" do
    note = build_note
    author = author_message
    answer = copilot_message(note.local_id)
    invalid_threads = [
      [], "text", 1, {},
      thread_payload.merge("version" => 1.0),
      thread_payload.merge("version" => 3),
      thread_payload.merge("originalStatus" => "resolved"),
      thread_payload.merge("author" => "fabricated"),
      thread_payload.merge("messages" => {}),
      thread_payload(messages: [ nil ]),
      thread_payload(messages: [ author.merge("role" => "user") ]),
      thread_payload(messages: [ author.merge("id" => "not-a-uuid") ]),
      thread_payload(messages: [ author.merge("id" => note.local_id) ]),
      thread_payload(messages: [ author, author ]),
      thread_payload(messages: [ author.merge("body" => " \n") ]),
      thread_payload(messages: [ author.merge("body" => 123) ]),
      thread_payload(messages: [ author.merge("status" => "resolved") ]),
      thread_payload(messages: [ author.merge("createdAt" => Time.current.iso8601) ]),
      thread_payload(messages: [ answer.merge("status" => "sent") ]),
      thread_payload(messages: [ answer.merge("body" => "") ]),
      thread_payload(messages: [ answer.except("requestIds") ]),
      thread_payload(messages: [ answer.merge("requestIds" => []) ]),
      thread_payload(messages: [ answer.merge("requestIds" => [ note.local_id, note.local_id ]) ]),
      thread_payload(messages: [ answer.merge("requestIds" => [ SecureRandom.uuid ]) ]),
      thread_payload(messages: [ copilot_message(author["id"]), author ]),
      thread_payload(messages: [ answer, copilot_message(answer["id"]) ])
    ]
    invalid_threads.each do |thread|
      note.note_thread = thread
      assert_not note.valid?, thread.inspect
      assert note.errors[:note_thread].any?, note.errors.full_messages.inspect
    end
    note.note_thread = thread_payload(messages: [ author, copilot_message(note.local_id, author["id"]) ])
    assert note.valid?, note.errors.full_messages.inspect
  end

  test "enforces UTF8 author bytes and JavaScript UTF16 answer length" do
    note = build_note
    author = author_message(body: "é" * 5_000)
    answer = copilot_message(note.local_id).merge("body" => "😀" * 1_000)
    note.note_thread = thread_payload(messages: [ author, answer ])
    assert note.valid?, note.errors.full_messages.inspect
    note.note_thread["messages"][0]["body"] += "é"
    assert_not note.valid?
    note.note_thread["messages"][0]["body"] = "Valid"
    note.note_thread["messages"][1]["body"] += "a"
    assert_not note.valid?
    note.note_thread["messages"][1]["body"] = "a" * 2_000
    assert note.valid?, note.errors.full_messages.inspect
    note.note_thread["messages"][1]["body"] += "a"
    assert_not note.valid?
    note.note_thread["messages"][1]["body"] = "\xFF".dup.force_encoding(Encoding::UTF_8)
    assert_not note.valid?
    assert_includes note.errors[:note_thread], "must contain valid UTF-8 text"
  end

  test "bounds message count and complete serialized UTF8 thread size" do
    note = build_note
    note.note_thread = thread_payload(messages: 100.times.map { author_message })
    assert note.valid?, note.errors.full_messages.inspect
    note.note_thread["messages"] << author_message
    assert_not note.valid?

    note.note_thread = thread_payload(messages: 4.times.map { author_message(body: "<" * 7_500) })
    remaining = 32_768 - JSON.generate(note.note_thread).bytesize
    note.note_thread["messages"][0]["body"] += "a" * remaining
    assert_equal 32_768, JSON.generate(note.note_thread).bytesize
    assert note.valid?, note.errors.full_messages.inspect
    note.note_thread["messages"][0]["body"] += "é"
    assert_not note.valid?
    note.note_thread["messages"][0]["body"].delete_suffix!("é")
    note.save!
    assert_equal 32_768, JSON.generate(note.reload.note_thread).bytesize
  end

  test "legacy backfill preserves the original while unthreaded edits and deletion remain valid" do
    note = build_note
    note.save!
    note.update!(body: "Legacy client edit")
    note.assign_attributes(body: "Changed during backfill", note_thread: thread_payload)
    assert_not note.save
    assert_includes note.errors[:body], "cannot change when saving a thread"
    assert_equal "Legacy client edit", note.reload.body
    assert_nil note.note_thread
    note.update!(note_thread: thread_payload)
    assert_equal "Legacy client edit", note.reload.body

    deleted = build_note(prototype: note.prototype, user: note.user)
    deleted.save!
    deleted.update!(body: nil, deleted_at: Time.current, note_thread: thread_payload)
    assert_nil deleted.reload.body
    assert_nil deleted.note_thread
  end

  test "saved original and history are immutable except author status and appended messages" do
    note = build_note
    author = author_message
    note.note_thread = thread_payload(messages: [ author, copilot_message(note.local_id, author["id"]) ])
    note.save!
    original = note.note_thread.deep_dup
    changes = [
      ->(thread) { thread["messages"].pop },
      ->(thread) { thread["messages"].reverse! },
      ->(thread) { thread["messages"][0]["id"] = SecureRandom.uuid },
      ->(thread) { thread["messages"][0]["body"] = "Edited" },
      ->(thread) { thread["messages"][0]["role"] = "copilot" },
      ->(thread) { thread["messages"][1]["body"] = "Edited answer" },
      ->(thread) { thread["messages"][1]["status"] = "blocked" },
      ->(thread) { thread["messages"][1]["requestIds"] = [ note.local_id ] }
    ]
    changes.each do |change|
      note.note_thread = original.deep_dup
      change.call(note.note_thread)
      assert_not note.save
      assert_equal original, note.reload.note_thread
    end
    note.note_thread = nil
    assert_not note.save
    note.reload.body = "Edited original"
    assert_not note.save

    note.reload
    note.note_thread["originalStatus"] = "sent"
    note.note_thread["messages"][0]["status"] = "blocked"
    note.note_status = "sent"
    note.note_thread["messages"] << author_message(status: "ready")
    assert note.save, note.errors.full_messages.inspect
  end

  test "ordinary comments reject threads in model and database and notes cannot get review replies" do
    build = builds.create_successful
    ordinary = ReviewComment.create! \
      prototype: build.prototype, build:, user: users.create, body: "Review", anchor: valid_anchor
    ordinary.note_thread = thread_payload
    assert_not ordinary.save
    assert_raises(ActiveRecord::StatementInvalid) { ordinary.update_columns(note_thread: thread_payload) }

    note = build_note(prototype: build.prototype, user: ordinary.user)
    note.note_thread = thread_payload
    note.save!
    [ [], "text", { "padding" => "a" * 32_768 } ].each do |thread|
      assert_raises(ActiveRecord::StatementInvalid) { note.update_columns(note_thread: thread) }
    end
    assert_no_difference [ "ReviewComment.count", "Notification.count", "ReviewThreadRead.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        note.thread.create_reply!(user: note.user, body: "Forbidden ordinary reply")
      end
    end
  end

  test "deletion clears conversation text and cannot restore the original" do
    note = build_note
    note.note_thread = thread_payload(messages: [ author_message, copilot_message(note.local_id) ])
    note.save!
    note.update!(body: nil, deleted_at: Time.current)
    assert_nil note.reload.note_thread
    assert_nil note.body
    note.assign_attributes(body: "Restored", deleted_at: nil, note_thread: thread_payload)
    assert_not note.save
  end

  private

  def build_note(**attributes)
    ReviewComment.new \
      prototype: attributes.fetch(:prototype) { prototypes.create },
      user: attributes.fetch(:user) { users.create },
      kind: "improvement_note", local_id: SecureRandom.uuid, note_revision: 1,
      note_status: "open", body: "Original request", anchor: valid_anchor
  end

  def thread_payload(original: "open", messages: [])
    { "version" => 1, "originalStatus" => original, "messages" => messages }
  end

  def author_message(status: "open", body: "Follow-up request")
    { "id" => SecureRandom.uuid, "role" => "author", "body" => body, "status" => status }
  end

  def copilot_message(*request_ids)
    { "id" => SecureRandom.uuid, "role" => "copilot", "body" => "Prior answer", "status" => "ready", "requestIds" => request_ids }
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
