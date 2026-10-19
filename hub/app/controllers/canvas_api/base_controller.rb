# Authenticates extension requests independently of Hub's browser session.
class CanvasApi::BaseController < ActionController::API
  include CanvasApiCompatibility
  include SecurityAuditing
  include SecurityRateLimiting
  before_action :authenticate_canvas
  before_action :authorize_repository
  before_action :verify_live_connection
  before_action :record_canvas_activity
  before_action { response.headers["Cache-Control"] = "private, no-store" }

  rescue_from GithubClient::Error, with: :repository_unavailable
  rescue_from CanvasGrant::Expired, with: -> { head :unauthorized }

  private

  # Keeps the bearer secret in the extension's Node process, not browser cookies.
  def authenticate_canvas
    header = request.headers["Authorization"].to_s
    secret = header.delete_prefix("Bearer ") if header.start_with?("Bearer ")
    Current.canvas_grant = CanvasGrant.authenticate(secret)
    head :unauthorized if Current.canvas_grant.nil?
  end

  # Caches read permission briefly; writes still recheck GitHub immediately.
  def authorize_repository
    return if performed?

    @repository = Current.canvas_grant.repository
    if params[:repository_github_id].present? &&
        params[:repository_github_id].to_s != @repository.route_id.to_s
      return head :not_found
    end

    @repository_permission = @repository.authorization.permission_for(Current.user, fresh: fresh_permission?)
    head :forbidden if !@repository.authorization.sufficient?(@repository_permission, minimum: :read)
  end

  # Writes recheck GitHub immediately; reads may use a recently confirmed permission.
  def fresh_permission?
    !request.get?
  end

  def require_writer
    head :forbidden if !@repository.authorization.sufficient?(@repository_permission, minimum: :write)
  end

  # A repository check may have waited on GitHub while the deployment ended sessions.
  def verify_live_connection
    return if performed?

    head :unauthorized if CanvasGrant.authenticated.where(id: Current.canvas_grant.id).none?
  end

  # Polls, cable tickets, and token renewals never send this trusted-client assertion.
  def record_canvas_activity
    return if performed? || request.headers["X-Replica-Canvas-Activity"] != "interactive"

    Current.canvas_grant.record_activity!
  end

  def repository_unavailable
    head :service_unavailable
  end
end
