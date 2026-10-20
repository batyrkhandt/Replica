class AddDraftReviewRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :draft_review_revisions do |table|
      table.references :prototype, null: false, foreign_key: { on_delete: :restrict }
      table.references :build, foreign_key: { on_delete: :restrict }
      table.string :tree_sha, null: false
      table.string :base_commit_sha, null: false
      table.timestamps
    end
    add_index :draft_review_revisions, %i[prototype_id tree_sha base_commit_sha],
      unique: true, name: "index_draft_reviews_on_source"
    add_index :draft_review_revisions, %i[id prototype_id], unique: true
    add_foreign_key :draft_review_revisions, :builds,
      column: %i[build_id prototype_id], primary_key: %i[id prototype_id], on_delete: :restrict
    %w[tree_sha base_commit_sha].each do |column|
      add_check_constraint :draft_review_revisions,
        "length(#{column}) = 40 AND #{column} NOT GLOB '*[^0-9a-f]*'",
        name: "draft_review_revisions_#{column}"
    end

    add_reference :review_comments, :draft_review_revision
    add_foreign_key :review_comments, :draft_review_revisions,
      column: %i[draft_review_revision_id prototype_id], primary_key: %i[id prototype_id], on_delete: :restrict
    remove_check_constraint :review_comments,
      "(root_id IS NULL AND build_id IS NOT NULL AND anchor IS NOT NULL) " \
        "OR (root_id IS NOT NULL AND build_id IS NULL AND anchor IS NULL)",
      name: "review_comments_thread_shape"
    add_check_constraint :review_comments,
      "((root_id IS NULL AND (build_id IS NOT NULL OR draft_review_revision_id IS NOT NULL) AND anchor IS NOT NULL) " \
        "OR (root_id IS NOT NULL AND build_id IS NULL AND draft_review_revision_id IS NULL AND anchor IS NULL))",
      name: "review_comments_thread_shape"
  end
end
