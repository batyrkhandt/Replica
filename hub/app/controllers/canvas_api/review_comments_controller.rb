# Lists and changes review comments through a repository-scoped canvas grant.
class CanvasApi::ReviewCommentsController < CanvasApi::BaseController
  include ReviewCommentActions

  # Saves unpublished feedback immediately without inventing a Build number.
  # @route POST /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments (canvas_api_review_comments)
  def create
    attributes = params.require(:review_comment).permit(:draft_revision_id, :build_number, :body, anchor: {})
    return super if attributes[:draft_revision_id].nil?

    raise ActionController::BadRequest if attributes[:build_number].present?

    revision = @prototype.draft_review_revisions.find(attributes[:draft_revision_id])
    comment = revision.create_comment! \
      user: Current.user,
      body: attributes[:body],
      anchor: attributes[:anchor]
    render_review_comment_change comment, status: :created
  end

  private

  def review_comments
    @prototype.review_comments
  end

  def review_draft_revision
    return if params[:draft_revision_id].nil?

    @prototype.draft_review_revisions.find(params[:draft_revision_id])
  end
end
