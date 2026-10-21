require "test_helper"

class GithubAppConfiguration::TransferNetworkTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "transfer recovery performs every GitHub request outside write transactions" do
    configuration = github_app_configurations.create_installed
    owner = { id: 654, login: "new-team", type: "Organization" }
    responses = {
      [ :get, "/app" ] => { id: 123, slug: "transferred-hub", owner: },
      [ :get, "/orgs/new-team/installation" ] => { id: 789, app_id: 123, account: owner },
      [ :post, "/app/installations/789/access_tokens" ] => {
        token: "replacement-token", expires_at: 1.hour.from_now.iso8601
      },
      [ :get, "/installation/repositories?per_page=100&page=1" ] => { repositories: [] }
    }
    responses.each do |(method, path), payload|
      stub_request(method, "#{GITHUB_API_URL}#{path}").to_return do
        assert_not ActiveRecord::Base.connection.transaction_open?, path
        { status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" } }
      end
    end

    configuration.synchronize_repositories!

    assert_equal 789, configuration.reload.installation_id
    assert_equal 654, configuration.installation_account_github_id
  ensure
    if configuration&.persisted?
      SecurityAuditEvent
        .where("json_extract(context, '$.github_app_configuration_id') = ?", configuration.id)
        .delete_all
      configuration.destroy!
    end
  end
end
