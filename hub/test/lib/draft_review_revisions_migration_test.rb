require "test_helper"
require Rails.root.join("db/migrate/20260914080000_create_review_comments").to_s
require Rails.root.join("db/migrate/20260914150000_add_threads_to_review_comments").to_s
require Rails.root.join("db/migrate/20260914165500_add_reviewer_state_to_review_comments").to_s

class DraftReviewRevisionsMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class UpgradeRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "upgrading and rolling back preserve conversations, mentions, reactions, and read state" do
    UpgradeRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = UpgradeRecord.connection
    connection.create_table(:users)
    connection.create_table(:prototypes)
    connection.create_table(:builds) do |table|
      table.references :prototype, null: false, foreign_key: true
    end
    connection.create_table(:github_identities)
    [ CreateReviewComments, AddThreadsToReviewComments, AddReviewerStateToReviewComments ].each do |migration|
      instance = migration.new
      instance.suppress_messages { instance.exec_migration(connection, :up) }
    end
    connection.create_table(:comment_mentions) do |table|
      table.references :review_comment, null: false, foreign_key: { on_delete: :cascade }
      table.references :github_identity, null: false, foreign_key: { on_delete: :restrict }
      table.string :login, null: false
      table.timestamps
      table.index %i[review_comment_id github_identity_id], unique: true
    end
    connection.execute("INSERT INTO users (id) VALUES (1)")
    connection.execute("INSERT INTO prototypes (id) VALUES (1)")
    connection.execute("INSERT INTO builds (id, prototype_id) VALUES (1, 1)")
    connection.execute("INSERT INTO github_identities (id) VALUES (1)")
    connection.execute <<~SQL
      INSERT INTO review_comments
        (id, prototype_id, build_id, user_id, body, anchor, activity_version, created_at, updated_at)
      VALUES (1, 1, 1, 1, 'Keep the heading', '{"schemaVersion":1}', 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    connection.execute <<~SQL
      INSERT INTO review_comments
        (id, prototype_id, root_id, user_id, body, created_at, updated_at)
      VALUES (2, 1, 1, 1, 'Agreed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    connection.execute <<~SQL
      INSERT INTO comment_mentions
        (review_comment_id, github_identity_id, login, created_at, updated_at)
      VALUES (2, 1, 'mona', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    connection.execute <<~SQL
      INSERT INTO review_comment_reactions
        (review_comment_id, user_id, content, created_at, updated_at)
      VALUES (1, 1, 'heart', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             (2, 1, '+1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    connection.execute <<~SQL
      INSERT INTO review_thread_reads
        (root_id, user_id, last_seen_activity_version, read_at, created_at, updated_at)
      VALUES (1, 1, 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    tables = %w[review_comments comment_mentions review_comment_reactions review_thread_reads]
    original = tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
    pool = UpgradeRecord.connection_pool
    context = ActiveRecord::MigrationContext.new \
      Rails.root.join("db/migrate").to_s, pool.schema_migration, pool.internal_metadata
    migration = context.migrations.find { |candidate| candidate.version == 20261020080000 }

    # The real migrator must decide transaction ownership, rather than an existing test transaction.
    tasks = ActiveRecord::Tasks::DatabaseTasks
    original_migration_class = tasks.method(:migration_class)
    tasks.define_singleton_method(:migration_class) { UpgradeRecord }
    assert_equal 0, connection.open_transactions
    [ :up, :down ].each do |direction|
      ActiveRecord::Migration.suppress_messages do
        migrator = ActiveRecord::Migrator.new \
          direction, [ migration ], pool.schema_migration, pool.internal_metadata, migration.version
        migrator.run
      end
      tables.each do |table|
        rows = connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a
        rows.each { |row| row.delete("draft_review_revision_id") }
        assert_equal original.fetch(table), rows, "#{table} changed during #{direction}"
        end
      assert_equal 1, connection.select_value("PRAGMA foreign_keys"), direction.to_s
      assert_empty connection.select_all("PRAGMA foreign_key_check").to_a, direction.to_s
    end
  ensure
    tasks.define_singleton_method(:migration_class, original_migration_class) if original_migration_class
    UpgradeRecord.connection_pool.disconnect!
  end
end
