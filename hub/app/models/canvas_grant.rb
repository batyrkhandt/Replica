# == Schema Information
#
# Table name: canvas_grants
# Database name: primary
#
#  id                     :integer          not null, primary key
#  expires_at             :datetime         not null
#  fresh_authorized_at    :datetime
#  inactive_at            :datetime
#  last_active_at         :datetime
#  learnings_consented_at :datetime
#  refresh_token_digest   :string
#  revoked_at             :datetime
#  token_digest           :string           not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  repository_id          :integer          not null
#  user_id                :integer          not null
#
# Indexes
#
#  index_canvas_grants_on_expires_at            (expires_at)
#  index_canvas_grants_on_inactive_at           (inactive_at)
#  index_canvas_grants_on_refresh_token_digest  (refresh_token_digest) UNIQUE
#  index_canvas_grants_on_repository_id         (repository_id)
#  index_canvas_grants_on_revoked_at            (revoked_at) WHERE revoked_at IS NOT NULL
#  index_canvas_grants_on_token_digest          (token_digest) UNIQUE
#  index_canvas_grants_on_user_id               (user_id)
#
# Foreign Keys
#
#  repository_id  (repository_id => repositories.id) ON DELETE => cascade
#  user_id        (user_id => users.id) ON DELETE => cascade
#
# Check Constraints
#
#  canvas_grants_expiry     (expires_at > created_at)
#  canvas_grants_renewable  ((refresh_token_digest IS NULL AND last_active_at IS NULL AND inactive_at IS NULL) OR (refresh_token_digest IS NOT NULL AND last_active_at IS NOT NULL AND inactive_at IS NOT NULL AND inactive_at > last_active_at))
#
# Authenticates one approved Copilot canvas connection to a single repository.
class CanvasGrant < ApplicationRecord
  TOKEN_LIFETIME = 7.days
  TOKEN_PATTERN = /\Arp_[A-Za-z0-9_-]{43}\z/
  REFRESH_PATTERN = /\Arr_[A-Za-z0-9_-]{43}\z/
  INACTIVITY_LIFETIME = 30.days

  class Expired < StandardError; end

  belongs_to :user
  belongs_to :repository

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  scope :current, -> {
    where(revoked_at: nil).where(
      "(refresh_token_digest IS NULL AND expires_at > :now) OR " \
      "(refresh_token_digest IS NOT NULL AND inactive_at > :now)", now: Time.current
    )
  }
  scope :authenticated, -> { current.where("expires_at > ?", Time.current) }

  # Looks up a bearer secret without keeping its plaintext in Hub.
  def self.authenticate(secret)
    return if !secret.is_a?(String) || !secret.match?(TOKEN_PATTERN)

    authenticated.where(token_digest: Digest::SHA256.hexdigest(secret))
      .includes(:user, :repository).first
  end

  # Finds a renewable connection, including one whose access token has expired.
  def self.for_refresh(secret)
    return if !secret.is_a?(String) || !secret.match?(REFRESH_PATTERN)

    current.find_by(refresh_token_digest: Digest::SHA256.hexdigest(secret))
  end

  # Rotates only the access secret after the controller checks fresh repository access.
  def renew!
    with_lock do
      raise Expired if refresh_token_digest.nil? || revoked_at || inactive_at <= Time.current

      secret = "rp_#{SecureRandom.urlsafe_base64(32)}"
      update! \
        token_digest: Digest::SHA256.hexdigest(secret),
        expires_at: [ TOKEN_LIFETIME.from_now, inactive_at ].min
      SecurityAuditEvent.record! \
        action: "canvas_connection.renew", outcome: "succeeded", repository:, actor: user,
        context: (Current.security_audit_context || {}).merge(canvas_grant_id: id)
      credentials(secret)
    end
  end

  # Records eligible interaction only before the existing deadline.
  def record_activity!
    with_lock do
      now = Time.current
      raise Expired if revoked_at || expires_at <= now || (inactive_at && inactive_at <= now)
      return if refresh_token_digest.nil?

      update!(last_active_at: now, inactive_at: now + INACTIVITY_LIFETIME)
      SecurityAuditEvent.record! \
        action: "canvas_connection.activity", outcome: "succeeded", repository:, actor: user,
        context: (Current.security_audit_context || {}).merge(canvas_grant_id: id)
    end
  end

  # Returns access credentials without disclosing the stored refresh digest.
  def credentials(secret)
    {
      accessToken: secret, expiresAt: expires_at.iso8601,
      connectionId: id, inactiveAt: inactive_at&.iso8601,
      repository: repository.name_with_owner, login: user.login
    }
  end

  # Revokes the connection without changing the user's browser session.
  def revoke!
    with_lock do
      if revoked_at.nil?
        update!(revoked_at: Time.current)
        SecurityAuditEvent.record! \
          action: "canvas_connection.revoke", outcome: "succeeded", repository:, actor: user,
          context: (Current.security_audit_context || {}).merge(canvas_grant_id: id)
      end
    end
    ActionCable.server.remote_connections.where(current_user: user, credential_identity: to_gid_param).disconnect
  end

  # Discards unusable grants without retaining revoked credentials indefinitely.
  def self.clear_expired!
    where(refresh_token_digest: nil, expires_at: ..Time.current)
      .or(where(inactive_at: ..Time.current)).or(where.not(revoked_at: nil)).delete_all
  end
end
