require "test_helper"
require Rails.root.join("db/migrate/20261021195500_add_installation_account_to_github_app_configurations").to_s

class GithubAppInstallationAccountMigrationTest < ActiveSupport::TestCase
  class UpgradeRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "backfills saved installation accounts and enforces their identity independently of current ownership" do
    UpgradeRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = UpgradeRecord.connection
    connection.create_table(:github_app_configurations) do |table|
      table.bigint :owner_github_id, null: false
      table.bigint :installation_id
    end
    connection.execute <<~SQL
      INSERT INTO github_app_configurations (owner_github_id, installation_id)
      VALUES (321, 456), (654, NULL)
    SQL
    migration = AddInstallationAccountToGithubAppConfigurations.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.up }

    accounts = connection.select_values \
      "SELECT installation_account_github_id FROM github_app_configurations ORDER BY id"
    assert_equal [ 321, nil ], accounts
    connection.execute("UPDATE github_app_configurations SET owner_github_id = 789 WHERE id = 1")
    assert_equal 321, connection.select_value(
      "SELECT installation_account_github_id FROM github_app_configurations WHERE id = 1"
    )
    [ "NULL", "0", "-1" ].each do |invalid_account|
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute \
          "UPDATE github_app_configurations SET installation_account_github_id = #{invalid_account} WHERE id = 1"
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("UPDATE github_app_configurations SET installation_account_github_id = 654 WHERE id = 2")
    end

    migration.suppress_messages { migration.down }

    assert_equal %w[id owner_github_id installation_id],
      connection.columns(:github_app_configurations).map(&:name)
    assert_equal 456, connection.select_value("SELECT installation_id FROM github_app_configurations WHERE id = 1")
  ensure
    UpgradeRecord.connection_pool.disconnect!
  end
end
