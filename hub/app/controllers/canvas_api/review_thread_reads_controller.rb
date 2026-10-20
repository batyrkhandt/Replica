# Tracks the paired user's seen version of an existing Hub thread.
class CanvasApi::ReviewThreadReadsController < CanvasApi::BaseController
  include HasReviewCommentContext

  prepend_before_action :reject_large_request

  # @route POST /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/read (canvas_api_review_comment_read)
  def create
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    value = params.require(:review_thread_read).permit(:activity_version)[:activity_version]
    root.thread.record_read_by! Current.user, activity_version: positive_activity_version(value)
    render_review_comment_change root, broadcast: false
  end

  # Clears only the paired reviewer's read state.
  # @route DELETE /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/read (canvas_api_review_comment_read)
  def destroy
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    root.thread.record_unread_by! Current.user
    render_review_comment_change root, broadcast: false
  end
end
