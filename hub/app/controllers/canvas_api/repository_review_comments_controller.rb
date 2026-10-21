class CanvasApi::RepositoryReviewCommentsController < CanvasApi::BaseController
  include ReviewCommentPages

  # @route GET /api/canvas/repositories/:repository_github_id/review_comments (canvas_api_repository_review_comments)
  def index
    filter = improvement_notes_filter
    page = if filter == "exclude"
      ReviewComment.page_for_repository(@repository, viewer: Current.user, cursor: pagination_cursor, page_size:)
    else
      CanvasCommentPage.read \
        notes: ImprovementComment.roots.where(prototype: @repository.reviewable_prototypes),
        reviews: filter == "include" ? ReviewComment.where(prototype: @repository.reviewable_prototypes) : nil,
        purpose: "repository/#{@repository.id}/viewer/#{Current.user.id}/#{filter}",
        cursor: pagination_cursor,
        page_size: page_size do |candidate|
          review_comment_page_json(candidate).to_json.bytesize <= ImprovementComment::PAGE_MAXIMUM_BYTES
        end
    end
    render json: review_comment_page_json(page)
  end

  private

  def review_comment_page_json(page)
    prepare_viewer_thread_reads(page.records)
    {
      comments: page.records.map do |comment|
        prototype = comment.prototype
        canvas_comment_json(comment).merge \
          prototype: { id: prototype.id, name: prototype.name, branch: prototype.branch_name }
      end,
      nextCursor: page.next_cursor,
      hasMore: page.has_more
    }
  end
end
