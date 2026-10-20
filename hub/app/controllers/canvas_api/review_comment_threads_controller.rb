class CanvasApi::ReviewCommentThreadsController < CanvasApi::BaseController
  include ReviewCommentPages

  RESPONSE_MAXIMUM_BYTES = 60 * 1024

  rescue_from ReviewComment::ResponseTooLarge, with: -> { head :content_too_large }
  rescue_from ReviewComment::ThreadChanged, with: -> { head :conflict }

  # @route GET /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:id/thread (canvas_api_review_comment_thread)
  def show
    @prototype = @repository.reviewable_prototypes.find(params[:prototype_id])
    @root = @prototype.review_comments.roots.includes(:build, :user, :resolved_by, :reactions).find(params[:id])
    @activity_version = @root.activity_version
    @reply_count = @root.replies.not_deleted.count
    prepare_viewer_thread_reads([ @root ])
    page = ReviewComment.reply_page_for \
      @root,
      viewer: Current.user,
      cursor: pagination_cursor,
      page_size: page_size do |candidate|
        thread_page_json(candidate).to_json.bytesize <= RESPONSE_MAXIMUM_BYTES
      end
    payload = thread_page_json(page)
    raise ReviewComment::ThreadChanged if @root.reload.activity_version != @activity_version

    render json: payload
  end

  private

  def thread_page_json(page)
    {
      root: review_comment_json(@root).merge(
        prototype: { id: @prototype.id, name: @prototype.name, branch: @prototype.branch_name }
      ),
      replies: page.records.map { review_comment_json(_1) },
      replyCount: @reply_count,
      nextCursor: page.next_cursor,
      hasMore: page.has_more
    }
  end
end
