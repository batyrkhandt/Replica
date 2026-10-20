# == Schema Information
#
# Table name: draft_review_revisions
# Database name: primary
#
#  id              :integer          not null, primary key
#  base_commit_sha :string           not null
#  tree_sha        :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  build_id        :integer
#  prototype_id    :integer          not null
#
# Indexes
#
#  index_draft_review_revisions_on_build_id             (build_id)
#  index_draft_review_revisions_on_id_and_prototype_id  (id,prototype_id) UNIQUE
#  index_draft_review_revisions_on_prototype_id         (prototype_id)
#  index_draft_reviews_on_source                        (prototype_id,tree_sha,base_commit_sha) UNIQUE
#
# Foreign Keys
#
#  [build_id, prototype_id]  ([build_id, prototype_id] => builds[id, prototype_id]) ON DELETE => restrict
#  build_id                  (build_id => builds.id) ON DELETE => restrict
#  prototype_id              (prototype_id => prototypes.id) ON DELETE => restrict
#
# Check Constraints
#
#  draft_review_revisions_base_commit_sha  (length(base_commit_sha) = 40 AND base_commit_sha NOT GLOB '*[^0-9a-f]*')
#  draft_review_revisions_tree_sha         (length(tree_sha) = 40 AND tree_sha NOT GLOB '*[^0-9a-f]*')
#
# Keeps local review conversations attached to the source content that was reviewed.
class DraftReviewRevision < ApplicationRecord
  belongs_to :prototype
  belongs_to :build, optional: true
  has_many :review_comments, dependent: :restrict_with_exception

  validates :tree_sha, :base_commit_sha, format: { with: Build::COMMIT_SHA_FORMAT }
  validates :tree_sha, uniqueness: { scope: %i[prototype_id base_commit_sha] }
  validate :build_matches_prototype
  validate :identity_is_unchanged, on: :update

  # Creates a hidden review owner without registering, publishing, or reviving a branch.
  def self.prepare!(repository:, branch:, tree_sha:, base_commit_sha:)
    if !branch.is_a?(String) || branch.blank? || branch.bytesize > 255 ||
        !repository.prototype_branch?(branch)
      raise ActiveRecord::RecordNotFound
    end

    repository.with_lock do
      prototype = repository.reviewable_prototypes.active.find_by(branch_name: branch)
      if prototype.nil?
        raise ActiveRecord::RecordNotFound if repository.prototypes.exists?(branch_name: branch)

        prototype = repository.prototypes.create!(branch_name: branch)
      end
      prototype.with_lock do
        prototype.draft_review_revisions.find_by(tree_sha:, build_id: nil) ||
          prototype.draft_review_revisions.find_or_create_by!(tree_sha:, base_commit_sha:)
      end
    end
  end

  # Saves the root under the same lock that associates an imported Build.
  def create_comment!(user:, body:, anchor:)
    profiles = ReviewComment::Mentions.resolve(repository: prototype.repository, body:)
    prototype.with_lock do
      reload
      comment = ReviewComment.create! \
        prototype:,
        draft_review_revision: self,
        build:,
        user:,
        body:,
        anchor: anchor
      comment.mentions.sync!(profiles)
      Notification.record_comment!(comment) if build_id
      comment
    end
  end

  private

  # Enforces the same owner for a revision and its eventual Build.
  def build_matches_prototype
    return if build.nil?

    errors.add(:build, "must belong to this prototype") if build.prototype_id != prototype_id
    errors.add(:build, "must be successful") if build.state != "successful"
  end

  # Source identity is immutable and a matched revision cannot move to another Build.
  def identity_is_unchanged
    %i[prototype_id tree_sha base_commit_sha].each do |attribute|
      errors.add(attribute, "cannot change") if public_send("will_save_change_to_#{attribute}?")
    end
    errors.add(:build, "cannot change") if build_id_was && will_save_change_to_build_id?
  end
end
