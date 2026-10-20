# Selects bounded gallery pages and registration authors within one repository.
class Repository::PrototypeListing < ActiveRecord::AssociatedObject
  class InvalidQuery < StandardError; end

  PAGE_SIZE = 24
  AUTHORS_PAGE_SIZE = 20
  QUERY_MAXIMUM_LENGTH = 200
  Page = Data.define \
    :prototypes, :query, :author, :author_user, :matching_count,
    :previous_cursor, :next_cursor

  # Filters before paging, leaving Build hydration to the selected records.
  def page(user:, query: nil, author: nil, cursor: nil)
    query = normalized_query(query)
    author = normalized_author(author)
    author_id = author == "me" ? user.id : author.presence&.to_i
    relation = base
    relation = relation.where(author_id:) if author_id
    if query.present?
      relation = relation.left_joins(:author).where \
        "prototypes.name LIKE :query ESCAPE '\\' OR prototypes.description LIKE :query ESCAPE '\\' " \
          "OR prototypes.branch_name LIKE :query ESCAPE '\\' OR users.login LIKE :query ESCAPE '\\' " \
          "OR users.name LIKE :query ESCAPE '\\'",
        query: "%#{Prototype.sanitize_sql_like(query)}%"
    end
    matching_count = relation.count
    scope = cursor_scope(user, "prototypes", query:, author:)
    boundary = read_cursor(cursor, scope)
    selected = relation
    if boundary
      selected = before_boundary(selected, boundary, newer: boundary.fetch("direction") == "previous")
    end
    newer = boundary&.fetch("direction") == "previous"
    rows = selected.order(registered_at: newer ? :asc : :desc, id: newer ? :asc : :desc)
      .limit(PAGE_SIZE).to_a
    rows.reverse! if newer

    previous_cursor = nil
    next_cursor = nil
    if rows.any?
      first = prototype_boundary(rows.first, "previous")
      last = prototype_boundary(rows.last, "next")
      previous_cursor = write_cursor(scope, first) if before_boundary(relation, first, newer: true).exists?
      next_cursor = write_cursor(scope, last) if before_boundary(relation, last, newer: false).exists?
    end

    Page.new \
      prototypes: rows,
      query:,
      author:,
      author_user: author_id && User.where(id: base.select(:author_id)).find_by(id: author_id),
      matching_count:,
      previous_cursor:,
      next_cursor:
  end

  # Searches all eligible registration authors without enumerating the gallery.
  def authors(user:, query: nil, cursor: nil)
    query = normalized_query(query)
    relation = User.where(id: base.select(:author_id)).where.not(id: user.id)
    if query.present?
      relation = relation.where \
        "login LIKE :query ESCAPE '\\' OR name LIKE :query ESCAPE '\\'",
        query: "%#{User.sanitize_sql_like(query)}%"
    end
    scope = cursor_scope(user, "authors", query:)
    boundary = read_cursor(cursor, scope)
    if boundary
      raise InvalidQuery unless boundary["login"].is_a?(String) && boundary["login"].length <= 255

      relation = relation.where \
        "login > :login OR (login = :login AND id > :id)",
        login: boundary.fetch("login"), id: boundary.fetch("id")
    end
    rows = relation.order(:login, :id).limit(AUTHORS_PAGE_SIZE + 1).to_a
    authors = rows.first(AUTHORS_PAGE_SIZE)
    next_cursor = if rows.size > AUTHORS_PAGE_SIZE
      write_cursor(scope, { "login" => authors.last.login, "id" => authors.last.id })
    end
    { authors:, next_cursor: }
  end

  private

  # Shares eligibility with the gallery, not all stored branch owners.
  def base
    record.reviewable_prototypes.active.registered
  end

  # Rejects malformed or oversized input rather than silently changing its meaning.
  def normalized_query(value)
    return "" if value.nil?
    raise InvalidQuery unless value.is_a?(String) && value.length <= QUERY_MAXIMUM_LENGTH

    value.strip
  end

  # Named authors use immutable saved IDs; Me always resolves on the server.
  def normalized_author(value)
    return "" if value.nil? || value == ""
    return value if value == "me"
    raise InvalidQuery unless value.is_a?(String) && value.match?(/\A[1-9]\d{0,17}\z/)

    value
  end

  # Signs the query and viewer as well as the boundary to reject mixed continuations.
  def cursor_scope(user, kind, query:, author: "")
    { "version" => 1, "repository" => record.id, "user" => user.id, "kind" => kind, "query" => query, "author" => author }
  end

  # Validates only server-issued boundaries, never treating them as authorization.
  def read_cursor(value, scope)
    return if value.nil?
    raise InvalidQuery unless value.is_a?(String) && value.bytesize <= 2_048

    payload = verifier.verified(value)
    unless payload.is_a?(Hash) && payload.slice(*scope.keys) == scope &&
        payload["id"].is_a?(Integer) && payload["id"].positive?
      raise InvalidQuery
    end

    payload
  end

  # Keeps full timestamp precision for prototypes registered at the same time.
  def prototype_boundary(prototype, direction)
    { "time" => prototype.registered_at.iso8601(6), "id" => prototype.id, "direction" => direction }
  end

  # Uses strict tuple boundaries so new registrations do not shift later pages.
  def before_boundary(relation, boundary, newer:)
    unless boundary["time"].is_a?(String) && %w[previous next].include?(boundary["direction"])
      raise InvalidQuery
    end

    time = Time.iso8601(boundary.fetch("time"))
    operator = newer ? ">" : "<"
    relation.where \
      "prototypes.registered_at #{operator} :time " \
        "OR (prototypes.registered_at = :time AND prototypes.id #{operator} :id)",
      time:, id: boundary.fetch("id")
  rescue ArgumentError
    raise InvalidQuery
  end

  # Adds the boundary to the exact source query.
  def write_cursor(scope, boundary)
    verifier.generate(scope.merge(boundary))
  end

  # Separates gallery tokens from other signed Hub values.
  def verifier
    Rails.application.message_verifier("prototype-listing")
  end
end
