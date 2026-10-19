# Lets a signed-in Hub user approve or revoke a repository-scoped canvas connection.
class CanvasPairingsController < SuperglueController
  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route GET /canvas/pair/:user_code (canvas_pairing)
  def show
    @pairing = pending_pairing
    return head :gone if @pairing.nil?
    head :not_found if !@pairing.repository.authorization.authorized?(Current.user, fresh: true)
  end

  # @route POST /canvas/pair/:user_code (approve_canvas_pairing)
  def approve
    pairing = pending_pairing
    return head :gone if pairing.nil?
    generation = SessionRevocation.current.generation
    configuration = GithubAppConfiguration.current
    snapshot = configuration&.credential_snapshot || { configuration_id: nil, credential_revision: nil }
    return head :not_found if !pairing.repository.authorization.authorized?(Current.user, fresh: true, configuration:)

    SessionRevocation.with_generation!(generation) do
      if LocalDevelopment.enabled?
        pairing.approve! \
          Current.user,
          browser_session: Current.session,
          learnings_consent_version: params[:learnings_consent_version]
      else
        GithubAppConfiguration.with_credentials!(**snapshot) do
          pairing.approve! \
            Current.user,
            browser_session: Current.session,
            learnings_consent_version: params[:learnings_consent_version]
        end
      end
    end
    redirect_to canvas_connections_path, notice: I18n.t(
      "canvas_pairings.show.approved", repository: pairing.repository.name_with_owner
    ),
      status: :see_other
  rescue ActiveRecord::RecordNotFound, SessionRevocation::Superseded, GithubAppConfiguration::Superseded
    head :gone
  end

  # @route GET /canvas/connections (canvas_connections)
  def index
    @grants = CanvasGrant.current.where(user: Current.user)
      .includes(:repository).order(created_at: :desc)
  end

  # @route DELETE /canvas/connections/:id (canvas_connection)
  def destroy
    CanvasGrant.where(user: Current.user).find(params[:id]).revoke!
    redirect_to canvas_connections_path, notice: "Canvas connection revoked.", status: :see_other
  end

  private

  def security_audit_action
    { "approve" => "canvas_pairing.approve", "destroy" => "canvas_connection.revoke" }[action_name]
  end

  def pending_pairing
    CanvasPairing.includes(:repository).find_by(user_code: params[:user_code])
      &.then do |pairing|
        @repository = pairing.repository
        pairing if pairing.expires_at > Time.current &&
          pairing.approved_at.nil? && pairing.consumed_at.nil?
      end
  end

  def repository_unavailable
    head :service_unavailable
  end
end
