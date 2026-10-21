require "test_helper"

class GithubAppConfiguration::TransferRecoveryTest < ActiveSupport::TestCase
  test "polling recovers a personal App transfer without replacing credentials or live access" do
    configuration = github_app_configurations.create_installed \
      owner_github_id: 1001, owner_login: "octocat", owner_type: "User"
    user = users.create
    session = sessions.create(user:, fresh_authorized_at: Time.current)
    repository = repositories.create
    build = builds.create(prototype: prototypes.create(repository:))
    grant = preview_grants.create(build:, session:)
    credentials = configuration.slice \
      :github_app_id, :client_id, :client_secret, :private_key, :webhook_secret, :credential_revision
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:, slug: "transferred-hub")
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(repository.github_id, "new-team/prototype") ])

    configuration.synchronize_repositories!

    assert_equal credentials, configuration.reload.slice(*credentials.keys)
    assert_equal [ 654, "new-team", "Organization", "transferred-hub" ],
      configuration.slice(:owner_github_id, :owner_login, :owner_type, :app_slug).values
    assert_equal 789, configuration.installation_id
    assert_equal 654, configuration.installation_account_github_id
    assert_equal "active", configuration.installation_state
    assert_equal "new-team/prototype", repository.reload.name_with_owner
    assert_equal session.fresh_authorized_at, session.reload.fresh_authorized_at
    assert_equal session.id, grant.reload.session_id
    assert User.exists?(user.id)
    assert Build.exists?(build.id)
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/456/access_tokens"
  end

  test "polling discovers an organization transfer with the old owner's backfilled installation account" do
    configuration = github_app_configurations.create_installed
    owner = { id: 654, login: "new-team", type: "Organization" }
    repository = repositories.create
    stub_github_app(configuration:, owner:)
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(repository.github_id, "new-team/prototype") ])

    configuration.synchronize_repositories!

    assert_equal 654, configuration.reload.owner_github_id
    assert_equal 654, configuration.installation_account_github_id
    assert_equal 789, configuration.installation_id
    assert_equal "active", repository.reload.installation_state
  end

  test "polling discovers a missed installation even when no installation was saved" do
    configuration = github_app_configurations.create
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:)
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(2001, "new-team/prototype") ])

    configuration.synchronize_repositories!

    assert_equal 789, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
    assert Repository.active.exists?(github_id: 2001)
  end

  test "polling can discover a personal owner's installation without a saved installation ID" do
    configuration = github_app_configurations.create \
      owner_github_id: 1001, owner_login: "octocat", owner_type: "User"
    owner = { id: 1001, login: "octocat", type: "User" }
    stub_github_app(configuration:)
    stub_github_account_installation(account: owner)
    stub_github_installation_token
    stub_github_repositories([])

    configuration.synchronize_repositories!

    assert_equal 456, configuration.reload.installation_id
    assert_equal 1001, configuration.installation_account_github_id
    assert_requested :get, "#{GITHUB_API_URL}/users/octocat/installation", times: 1
  end

  test "confirmed absence after a transfer retains history and permits later polling recovery" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    prototype = prototypes.create(repository:)
    build = builds.create_successful(prototype:)
    user = users.create
    comment = ReviewComment.create! \
      prototype:, build:, user:, body: "Retain this review.",
      anchor: {
        schemaVersion: 1, kind: "element",
        route: { pathname: "/", search: "", hash: "" },
        selector: "#save", accessibleName: "Save", tagName: "button", selectedText: "",
        rect: { x: 20, y: 30, width: 100, height: 32 },
        viewport: { width: 1280, height: 720, scrollX: 0, scrollY: 0 },
        elementOffset: { x: 0.5, y: 0.5 }
      }
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:)
    account_request = stub_github_account_installation(account: owner, status: 404)

    configuration.synchronize_repositories!

    assert_equal 654, configuration.reload.owner_github_id
    assert_not_equal "active", configuration.installation_state
    assert_equal "removed", repository.reload.installation_state
    assert Build.exists?(build.id)
    assert Prototype.exists?(prototype.id)
    assert User.exists?(user.id)
    assert_equal "Retain this review.", comment.reload.body
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/456/access_tokens"

    remove_request_stub(account_request)
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(repository.github_id, "new-team/prototype") ])

    configuration.synchronize_repositories!

    assert_equal 789, configuration.reload.installation_id
    assert_equal 654, configuration.installation_account_github_id
    assert_equal "active", repository.reload.installation_state
    assert Build.exists?(build.id)
  end

  test "polling rejects another authenticated App identity before accepting its owner" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app \
      configuration:, app_id: 999,
      owner: { id: 654, login: "new-team", type: "Organization" }

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 321, configuration.reload.owner_github_id
    assert_equal 456, configuration.installation_id
    assert_equal "active", repository.reload.installation_state
    assert_not_requested :get, "#{GITHUB_API_URL}/orgs/new-team/installation"
  end

  test "an installation in another account cannot replace the current owner's installation" do
    configuration = github_app_configurations.create_installed
    owner = { id: 321, login: "github", type: "Organization" }
    stub_github_app(configuration:)
    stub_missing_saved_installation
    stub_github_account_installation \
      account: owner, payload: installation_payload(owner: owner.merge(id: 999), id: 789)

    assert_raises(GithubAppConfiguration::Installation::OwnerMismatch) do
      configuration.synchronize_repositories!
    end

    assert_equal 456, configuration.reload.installation_id
    assert_equal 321, configuration.installation_account_github_id
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/789/access_tokens"
  end

  test "an installation belonging to another App cannot be activated" do
    configuration = github_app_configurations.create_installed
    owner = { id: 321, login: "github", type: "Organization" }
    stub_github_app(configuration:)
    stub_missing_saved_installation
    stub_github_account_installation(account: owner, installation_id: 789, app_id: 999)

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 456, configuration.reload.installation_id
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/789/access_tokens"
  end

  test "a forbidden account lookup is not evidence that the installation was removed" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app(configuration:)
    stub_missing_saved_installation
    stub_github_account_installation \
      account: { id: 321, login: "github", type: "Organization" }, status: 403

    assert_raises(GithubClient::Forbidden) { configuration.synchronize_repositories! }

    assert_equal "active", configuration.reload.installation_state
    assert_equal 456, configuration.installation_id
    assert_equal "active", repository.reload.installation_state
  end

  test "a malformed App response cannot replace ownership or remove repositories" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_request(:get, "#{GITHUB_API_URL}/app")
      .to_return(status: 200, body: JSON.generate(id: 123, slug: "transferred-hub", owner: nil))

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 321, configuration.reload.owner_github_id
    assert_equal "active", configuration.installation_state
    assert_equal "active", repository.reload.installation_state
  end

  test "an App API timeout leaves the last known installation available" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_request(:get, "#{GITHUB_API_URL}/app").to_timeout

    assert_raises(GithubClient::Error) { configuration.synchronize_repositories! }

    assert_equal 321, configuration.reload.owner_github_id
    assert_equal 456, configuration.installation_id
    assert_equal "active", repository.reload.installation_state
  end

  test "a malformed installation response cannot be treated as confirmed absence" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app(configuration:)
    stub_missing_saved_installation
    stub_github_account_installation \
      account: { id: 321, login: "github", type: "Organization" }, payload: {}

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal "active", configuration.reload.installation_state
    assert_equal "active", repository.reload.installation_state
  end

  test "a null account installation response cannot remove the saved installation" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app(configuration:)
    stub_missing_saved_installation
    stub_request(:get, "#{GITHUB_API_URL}/orgs/github/installation")
      .to_return(status: 200, body: "null")

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 456, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
    assert_equal "active", repository.reload.installation_state
  end

  test "a null saved installation response cannot be treated as a missing installation" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app(configuration:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/456")
      .to_return(status: 200, body: "null")

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 456, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
    assert_equal "active", repository.reload.installation_state
    assert_not_requested :get, "#{GITHUB_API_URL}/orgs/github/installation"
  end

  test "a saved installation lookup cannot return another installation in the same account" do
    configuration = github_app_configurations.create_installed
    stub_github_app(configuration:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/456")
      .to_return(status: 200, body: JSON.generate(
        installation_payload(owner: { id: 321, login: "github", type: "Organization" }, id: 789)
      ))

    assert_raises(GithubClient::InvalidResponse) { configuration.synchronize_repositories! }

    assert_equal 456, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/789/access_tokens"
  end

  test "an owner rename and App slug change preserve the installation without recording a transfer" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    owner = { id: 321, login: "renamed-team", type: "Organization" }
    installed_at = configuration.installed_at
    stub_github_app(configuration:, owner:, slug: "renamed-hub")
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/456")
      .to_return(status: 200, body: JSON.generate(installation_payload(owner:, id: 456)))
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/installation/repositories")
      .with(query: { "page" => "1", "per_page" => "100" }).to_return do
        assert_equal "active", GithubAppConfiguration.find(configuration.id).installation_state
        assert_equal "active", repository.reload.installation_state
        {
          status: 200,
          body: JSON.generate(repositories: [
            repository_payload(repository.github_id, "renamed-team/prototype")
          ])
        }
      end

    assert_no_difference -> { SecurityAuditEvent.where(action: "github_app.transfer").count } do
      configuration.synchronize_repositories!
    end

    assert_equal "renamed-team", configuration.reload.owner_login
    assert_equal "renamed-hub", configuration.app_slug
    assert_equal 456, configuration.installation_id
    assert_equal 321, configuration.installation_account_github_id
    assert_equal installed_at, configuration.installed_at
    assert_equal "renamed-team/prototype", repository.reload.name_with_owner
  end

  test "an installation webhook recovers transferred ownership before accepting the new installation" do
    configuration = github_app_configurations.create_installed
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/789")
      .to_return(status: 200, body: JSON.generate(installation_payload(owner:, id: 789)))
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(2001, "new-team/prototype") ])

    deliver_installation(configuration:, owner:, id: 789, action: "created")

    assert_equal 654, configuration.reload.owner_github_id
    assert_equal 654, configuration.installation_account_github_id
    assert_equal 789, configuration.installation_id
    assert Repository.active.exists?(github_id: 2001)
  end

  test "a delayed old-owner uninstall cannot clear the recovered installation" do
    configuration = github_app_configurations.create_installed \
      owner_github_id: 654, owner_login: "new-team", installation_id: 789
    repository = repositories.create(name_with_owner: "new-team/prototype")
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/789")
      .to_return(status: 200, body: JSON.generate(installation_payload(owner:, id: 789)))
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([ repository_payload(repository.github_id, repository.name_with_owner) ])

    deliver_installation \
      configuration:, owner: { id: 321, login: "github", type: "Organization" },
      id: 456, action: "deleted"

    assert_equal 789, configuration.reload.installation_id
    assert_equal 654, configuration.owner_github_id
    assert_equal "active", configuration.installation_state
    assert_equal "active", repository.reload.installation_state
  end

  test "a delayed old-owner creation cannot restore an installation after a transfer" do
    configuration = github_app_configurations.create_installed \
      owner_github_id: 654, owner_login: "new-team", installation_id: 789
    owner = { id: 654, login: "new-team", type: "Organization" }
    stub_github_app(configuration:, owner:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/789")
      .to_return(status: 200, body: JSON.generate(installation_payload(owner:, id: 789)))
    stub_github_account_installation(account: owner, installation_id: 789)
    stub_github_installation_token(installation_id: 789)
    stub_github_repositories([])

    deliver_installation \
      configuration:, owner: { id: 321, login: "github", type: "Organization" },
      id: 456, action: "created"

    assert_equal 789, configuration.reload.installation_id
    assert_equal 654, configuration.owner_github_id
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/456/access_tokens"
  end

  test "a stale App response cannot roll ownership back after a newer transfer was recorded" do
    configuration = github_app_configurations.create_installed
    stub_request(:get, "#{GITHUB_API_URL}/app").to_return do
      GithubAppConfiguration.find(configuration.id).update! \
        owner_github_id: 654, owner_login: "new-team", installation_id: 789,
        installation_account_github_id: 654
      {
        status: 200,
        body: JSON.generate(id: 123, slug: "replica-hub-test",
          owner: { id: 321, login: "github", type: "Organization" })
      }
    end

    assert_raises(GithubAppConfiguration::Superseded, ActiveRecord::StaleObjectError) do
      configuration.synchronize_repositories!
    end

    assert_equal 654, configuration.reload.owner_github_id
    assert_equal 789, configuration.installation_id
    assert_not_requested :get, "#{GITHUB_API_URL}/orgs/github/installation"
  end

  test "an old repository response cannot reactivate repositories after a concurrent transfer" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    stub_github_app(configuration:)
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/456")
      .to_return(status: 200, body: JSON.generate(
        installation_payload(owner: { id: 321, login: "github", type: "Organization" }, id: 456)
      ))
    stub_github_account_installation(account: { id: 321, login: "github", type: "Organization" })
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/installation/repositories")
      .with(query: { "page" => "1", "per_page" => "100" }).to_return do
        GithubAppConfiguration.find(configuration.id).update! \
          owner_github_id: 654, owner_login: "new-team", installation_id: 789,
          installation_account_github_id: 654
        repository.update!(installation_state: "removed", removed_at: Time.current)
        { status: 200, body: JSON.generate(repositories: [
          repository_payload(repository.github_id, repository.name_with_owner)
        ]) }
      end

    assert_raises(GithubAppConfiguration::Superseded, ActiveRecord::StaleObjectError) do
      configuration.synchronize_repositories!
    end

    assert_equal 654, configuration.reload.owner_github_id
    assert_equal 789, configuration.installation_id
    assert_equal "removed", repository.reload.installation_state
  end

  test "a stale installation lookup cannot replace a newer owner's installation" do
    configuration = github_app_configurations.create
    owner = { id: 321, login: "github", type: "Organization" }
    stub_github_app(configuration:)
    stub_request(:get, "#{GITHUB_API_URL}/orgs/github/installation").to_return do
      GithubAppConfiguration.find(configuration.id).update! \
        owner_github_id: 654, owner_login: "new-team",
        installation_id: 789, installation_state: "active", installation_account_github_id: 654
      { status: 200, body: JSON.generate(installation_payload(owner:, id: 456)) }
    end

    assert_raises(GithubAppConfiguration::Superseded, ActiveRecord::StaleObjectError) do
      configuration.synchronize_repositories!
    end

    assert_equal 654, configuration.reload.owner_github_id
    assert_equal 789, configuration.installation_id
    assert_not_requested :post, "#{GITHUB_API_URL}/app/installations/456/access_tokens"
  end

  private

  def stub_missing_saved_installation
    stub_request(:get, "#{GITHUB_API_URL}/app/installations/456")
      .to_return(status: 404, body: "{}")
  end

  def installation_payload(owner:, id:)
    { id:, app_id: 123, account: owner, suspended_at: nil }
  end

  def deliver_installation(configuration:, owner:, id:, action:)
    body = JSON.generate(action:, installation: installation_payload(owner:, id:))
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", configuration.webhook_secret, body)}"
    GithubWebhook.process! \
      configuration:, body:, signature:, delivery_id: SecureRandom.uuid, event: "installation"
  end
end
