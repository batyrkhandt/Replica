# Prepares local review storage without claiming that the branch has been published.
class CanvasApi::DraftRevisionsController < CanvasApi::BaseController
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_revision

  # @route POST /api/canvas/draft_revision (canvas_api_draft_revision)
  def create
    attributes = %i[branch tree_sha base_commit_sha].to_h do |attribute|
      value = params.require(attribute)
      raise ActionController::BadRequest, "#{attribute} must be a string" unless value.is_a?(String)

      [ attribute, value ]
    end
    existing = DraftReviewRevision.joins(:prototype)
      .merge(@repository.reviewable_prototypes.active)
      .where(prototypes: { branch_name: attributes[:branch] }, tree_sha: attributes[:tree_sha])
    reusable = existing.where(build_id: nil).or(existing.where(base_commit_sha: attributes[:base_commit_sha])).exists?
    return if !reusable && !enforce_security_rate_limit(:comments)

    revision = DraftReviewRevision.prepare!(repository: @repository, **attributes)
    render json: {
      id: revision.id,
      prototypeId: revision.prototype_id,
      treeSha: revision.tree_sha,
      baseCommitSha: revision.base_commit_sha,
      buildNumber: revision.build&.number
    }
  end

  private

  def invalid_revision(error)
    render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
  end
end
