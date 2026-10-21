# Paginates the explicitly requested canvas feed across separate review and improvement tables.
class CanvasCommentPage
  # Selects small identities first so a page never loads a collection of large captures.
  def self.read(notes:, purpose:, cursor:, page_size:, reviews: nil, &fits)
    raise ReviewComment::InvalidPagination unless page_size.is_a?(Integer) && (1..ReviewComment::MAXIMUM_PAGE_SIZE).cover?(page_size)

    connection = ImprovementComment.connection
    queries = [
      notes.reselect(Arel.sql("id, created_at, 'improvement' AS source, " \
        "COALESCE(length(CAST(body AS BLOB)), 0) + COALESCE(length(CAST(anchor AS BLOB)), 0) + " \
        "COALESCE(length(CAST(capture AS BLOB)), 0) + COALESCE(length(CAST(author_snapshot AS BLOB)), 0) + 512 + " \
        "COALESCE((SELECT SUM(COALESCE(length(CAST(messages.body AS BLOB)), 0) + " \
        "COALESCE(length(CAST(messages.author_snapshot AS BLOB)), 0) + 256) " \
        "FROM improvement_comments messages WHERE messages.root_id = improvement_comments.id), 0) + " \
        "(SELECT COUNT(*) * 40 FROM improvement_comment_replies links WHERE links.prototype_id = improvement_comments.prototype_id " \
        "AND links.user_id = improvement_comments.user_id AND links.thread_key = improvement_comments.local_id) AS bytes")).to_sql
    ]
    if reviews
      queries << reviews.reselect(Arel.sql("id, created_at, 'review' AS source, " \
        "COALESCE(length(CAST(body AS BLOB)), 0) + COALESCE(length(CAST(anchor AS BLOB)), 0) AS bytes")).to_sql
    end
    verifier = Rails.application.message_verifier("canvas-comment-cursor")
    condition = ""
    if cursor.present?
      payload = verifier.verified(cursor, purpose:)
      raise ReviewComment::InvalidPagination unless payload.is_a?(Hash) &&
        payload["id"].is_a?(Integer) && payload["id"].positive? && %w[review improvement].include?(payload["source"])

      begin
        time = Time.iso8601(payload.fetch("created_at"))
      rescue ArgumentError, KeyError, TypeError
        raise ReviewComment::InvalidPagination
      end
      condition = ImprovementComment.sanitize_sql_array([
        "WHERE (created_at, id, source) < (?, ?, ?)", time, payload["id"], payload["source"]
      ])
    end
    ImprovementComment.transaction do
      entries = connection.select_all \
        "SELECT * FROM (#{queries.join(" UNION ALL ")}) #{condition} " \
        "ORDER BY created_at DESC, id DESC, source DESC LIMIT #{page_size + 1}"
      bytes = 0
      selected = entries.first(page_size).take_while do |entry|
        bytes += entry["bytes"]
        bytes <= ImprovementComment::PAGE_MAXIMUM_BYTES
      end
      raise ReviewComment::ResponseTooLarge if selected.empty? && entries.any?

      notes_by_id = notes.where(id: selected.filter_map { _1["id"] if _1["source"] == "improvement" })
        .includes(:prototype, :build, :user, replies: { request_links: :request }).index_by(&:id)
      reviews_by_id = reviews ? reviews.where(id: selected.filter_map { _1["id"] if _1["source"] == "review" })
        .includes(:prototype, :build, :user, :resolved_by, :reactions, comment_mentions: :github_identity).index_by(&:id) : {}
      records = selected.map { (_1["source"] == "review" ? reviews_by_id : notes_by_id).fetch(_1["id"]) }
      loop do
        more = entries.length > records.length
        last = records.last
        next_cursor = if more && last
          payload = {
            "created_at" => last.created_at.iso8601(6), "id" => last.id,
            "source" => last.is_a?(ImprovementComment) ? "improvement" : "review"
          }
          verifier.generate \
            payload,
            purpose:
        end
        page = ReviewComment::Page.new(records:, next_cursor:, has_more: more)
        return page if !fits || fits.call(page)

        raise ReviewComment::ResponseTooLarge if records.length <= 1

        records = records[...-1]
      end
    end
  end
end
