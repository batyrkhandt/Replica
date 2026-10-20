# Adds and removes reactions from live review messages.
class ReviewCommentReactionsController < ApplicationController
  include HasReviewCommentContext
  include ReviewCommentMutations

  prepend_before_action :reject_large_request

  # @route POST /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/reactions (repository_prototype_review_comment_reactions)
  def create
    attributes = reaction_attributes
    comment = @prototype.review_comments.not_deleted.find(params[:review_comment_id])
    comment.thread.add_reaction! \
      user: Current.user,
      content: attributes[:content],
      activity_version: positive_activity_version(attributes[:activity_version])

    render_review_comment_change comment, status: :created
  end

  # @route DELETE /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/reactions/:content (repository_prototype_review_comment_reaction)
  def destroy
    attributes = reaction_attributes
    comment = @prototype.review_comments.find(params[:review_comment_id])
    comment.thread.remove_reaction! \
      user: Current.user,
      content: params[:content],
      activity_version: positive_activity_version(attributes[:activity_version])

    render_review_comment_change comment
  end

  private

  # Accepts reaction fields and the thread version shown to the reviewer.
  def reaction_attributes
    params.require(:review_comment_reaction).permit(:content, :activity_version)
  end
end
