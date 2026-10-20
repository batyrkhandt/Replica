# Validates author requests and immutable Copilot answers without creating review replies.
class ReviewComment::NoteThreadContract < ActiveRecord::AssociatedObject
  VERSION = 2
  MAXIMUM_BYTES = 32_768
  MAXIMUM_MESSAGES = 100
  WORK_STATUSES = %w[open sent ready blocked].freeze
  UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/

  # Checks the wire format, aggregate status and append-only history.
  def validate_record
    thread = record.note_thread
    previous = record.note_thread_in_database
    if record.persisted? && (previous.present? || !thread.nil?) && record.will_save_change_to_body? && record.deleted_at.nil?
      record.errors.add(:body, "cannot change when saving a thread")
    end
    validate_history(previous, thread) if previous.present?
    return if thread.nil?
    return invalid("is only allowed on improvement notes") unless record.improvement_note?
    return invalid("must be a JSON object") unless thread.is_a?(Hash)
    return invalid("must be #{MAXIMUM_BYTES} UTF-8 bytes or fewer") if JSON.generate(thread).bytesize > MAXIMUM_BYTES
    return invalid("version must be 1 or #{VERSION}") unless thread["version"].is_a?(Integer) && [ 1, VERSION ].include?(thread["version"])
    fields = %w[messages originalStatus version]
    fields << "originalAuthor" if thread["version"] == 2 && thread.key?("originalAuthor")
    return invalid("thread fields do not match its version") unless thread.keys.sort == fields.sort
    return unless !thread.key?("originalAuthor") || validate_author(thread["originalAuthor"])
    return invalid("originalStatus must be a work status") unless WORK_STATUSES.include?(thread["originalStatus"])

    messages = thread["messages"]
    return invalid("messages must be an array of at most #{MAXIMUM_MESSAGES} messages") unless messages.is_a?(Array) && messages.size <= MAXIMUM_MESSAGES

    ids = [ record.local_id ]
    requests = [ record.local_id ]
    messages.each do |message|
      return unless validate_message(message, ids, requests, thread["version"])

      ids << message["id"]
      requests << message["id"] if message["role"] == "author"
    end
    statuses = [ thread["originalStatus"] ] + messages.filter_map { _1["status"] if _1["role"] == "author" }
    aggregate = %w[open sent blocked ready].find { statuses.include?(_1) }
    expected = record.note_status == "resolved" && statuses.all?("ready") ? "resolved" : aggregate
    invalid("status must match its requests") unless record.note_status == expected
  rescue JSON::GeneratorError, EncodingError
    invalid("must contain valid UTF-8 text")
  end

  private

  # Keeps saved requests in order and allows only author status changes.
  def validate_history(previous, thread)
    return if record.deleted_at.present? && thread.nil?
    return invalid("cannot be removed; upgrade the client to preserve this thread") unless thread.is_a?(Hash)
    return invalid("author snapshots cannot be removed; upgrade the client") if previous["version"] == 2 && thread["version"] != 2
    if previous.key?("originalAuthor") && previous["originalAuthor"] != thread["originalAuthor"]
      return invalid("the original author snapshot cannot change")
    end

    old_messages = previous["messages"]
    messages = thread["messages"]
    return invalid("saved messages cannot be removed or changed") unless messages.is_a?(Array) && messages.size >= old_messages.size

    old_messages.each_with_index do |old, index|
      current = messages[index]
      same = if old["role"] == "author" && current.is_a?(Hash)
        ignored = [ "status" ]
        ignored << "author" if !old.key?("author") && thread["version"] == 2
        old.except(*ignored) == current.except(*ignored)
      else
        old == current
      end
      invalid("saved messages cannot be removed, changed or reordered") unless same
    end
  end

  # Checks one message and references only requests that precede it.
  def validate_message(message, ids, requests, version)
    return invalid("messages must be JSON objects") unless message.is_a?(Hash)

    role = message["role"]
    return invalid("message role must be author or copilot") unless %w[author copilot].include?(role)

    keys = %w[id role body status]
    keys << "requestIds" if role == "copilot"
    keys << "author" if role == "author" && version == 2 && message.key?("author")
    return invalid("message fields do not match its role") unless message.keys.sort == keys.sort
    return invalid("message IDs must be unique UUIDs") unless message["id"].is_a?(String) && UUID.match?(message["id"]) && !ids.include?(message["id"])

    body = message["body"]
    return invalid("message body must be nonblank text") unless body.is_a?(String) && body.valid_encoding? && body.present?

    if role == "author"
      return unless !message.key?("author") || validate_author(message["author"])
      return invalid("author body must be 10000 UTF-8 bytes or fewer") if body.bytesize > ReviewComment::BODY_MAXIMUM_BYTES
      return invalid("author status must be a work status") unless WORK_STATUSES.include?(message["status"])
    else
      return invalid("copilot body must be 2000 UTF-16 code units or fewer") if body.encode(Encoding::UTF_16LE).bytesize > 4_000
      return invalid("copilot status must be ready or blocked") unless %w[ready blocked].include?(message["status"])

      references = message["requestIds"]
      unless references.is_a?(Array) && references.any? && references.uniq == references && references.all? { requests.include?(_1) }
        return invalid("requestIds must uniquely reference the original or preceding author messages")
      end
    end
    true
  end

  # Restricts snapshots to the note owner and supported GitHub avatar origin.
  def validate_author(author)
    unless author.is_a?(Hash) && author.keys.sort == %w[avatarUrl id login] &&
        author["id"].is_a?(Integer) && author["id"] == record.user_id &&
        author["login"].is_a?(String) && /\A[a-z0-9][a-z0-9-]{0,38}\z/i.match?(author["login"])
      return invalid("author snapshots must identify this note's owner")
    end
    previous = record.note_thread_in_database
    saved = [ previous&.dig("originalAuthor"), *previous&.fetch("messages", [])&.filter_map { _1["author"] } ].compact
    unless author["login"] == record.user.login || saved.include?(author)
      return invalid("new author snapshots must use the authenticated owner's login")
    end
    avatar = author["avatarUrl"]
    return true if avatar.nil?
    return invalid("author avatar must be a supported GitHub URL") unless avatar.is_a?(String) && avatar.length <= 2048

    url = URI.parse(avatar)
    return invalid("author avatar must be a supported GitHub URL") unless url.scheme == "https" && url.host == "avatars.githubusercontent.com" && url.userinfo.nil? && url.port == 443

    true
  rescue URI::InvalidURIError
    invalid("author avatar must be a supported GitHub URL")
  end

  # Adds a field-specific error and stops validation of an invalid shape.
  def invalid(message)
    record.errors.add(:note_thread, message)
    false
  end
end
