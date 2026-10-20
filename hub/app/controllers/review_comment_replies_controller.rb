# Adds replies to review comment threads.
class ReviewCommentRepliesController < ApplicationController
  include HasReviewCommentContext
  include ReviewCommentMutations

  prepend_before_action :reject_large_request, only: :create

  # @route POST /repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/replies (repository_prototype_review_comment_replies)
  def create
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    reply = root.thread.create_reply! \
      user: Current.user,
      body: comment_body

    render_review_comment_change reply, status: :created
  end
end
