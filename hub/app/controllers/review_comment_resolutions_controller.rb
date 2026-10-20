# Changes resolution state for review comment threads.
class ReviewCommentResolutionsController < ApplicationController
  include HasReviewCommentContext
  include ReviewCommentMutations

  # @route POST /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/resolution (repository_prototype_review_comment_resolution)
  def create
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    root.thread.resolve_by!(Current.user)

    render_review_comment_change root
  end

  # @route DELETE /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/resolution (repository_prototype_review_comment_resolution)
  def destroy
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    root.thread.reopen_by!(Current.user)

    render_review_comment_change root
  end
end
