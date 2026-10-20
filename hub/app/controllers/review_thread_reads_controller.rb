# Records which thread activity the current reviewer has seen.
class ReviewThreadReadsController < ApplicationController
  include HasReviewCommentContext

  prepend_before_action :reject_large_request, only: :create

  # @route POST /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/read (repository_prototype_review_comment_read)
  def create
    root = review_comments.roots.find(params[:review_comment_id])
    root.thread.record_read_by! \
      Current.user,
      activity_version: observed_activity_version

    render_review_comment_change root, broadcast: false
  end

  # Clears only the current reviewer's read state.
  # @route DELETE /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/read (repository_prototype_review_comment_read)
  def destroy
    root = review_comments.roots.find(params[:review_comment_id])
    root.thread.record_unread_by! Current.user
    render_review_comment_change root, broadcast: false
  end

  private

  # Requires the browser to name the positive activity version it displayed.
  def observed_activity_version
    value = params.require(:review_thread_read).permit(:activity_version)[:activity_version]
    positive_activity_version(value)
  end
end
