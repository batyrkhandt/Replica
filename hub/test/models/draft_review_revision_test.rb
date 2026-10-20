require "test_helper"

class DraftReviewRevisionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "committing unchanged draft content retains its pending conversations" do
    prototype = prototypes.create
    original = DraftReviewRevision.prepare! \
      repository: prototype.repository, branch: prototype.branch_name,
      tree_sha: "a" * 40, base_commit_sha: "b" * 40

    committed = DraftReviewRevision.prepare! \
      repository: prototype.repository, branch: prototype.branch_name,
      tree_sha: "a" * 40, base_commit_sha: "c" * 40

    assert_equal original, committed
    assert_equal "b" * 40, committed.base_commit_sha
    assert_nil committed.build
  end

  test "identifies revisions by Prototype tree and base commit together" do
    prototype = prototypes.create
    attributes = { prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40 }
    revision = DraftReviewRevision.create!(**attributes)

    assert_nil revision.build
    assert_not DraftReviewRevision.new(**attributes).valid?
    assert DraftReviewRevision.new(**attributes.merge(base_commit_sha: "c" * 40)).valid?
    assert DraftReviewRevision.new(**attributes.merge(tree_sha: "c" * 40)).valid?
    other = prototypes.create(repository: prototype.repository, branch_name: "prototype/other")
    assert DraftReviewRevision.new(**attributes.merge(prototype: other)).valid?
  end

  test "rejects malformed tree and base commit identities" do
    prototype = prototypes.create

    [ :tree_sha, :base_commit_sha ].each do |field|
      [ nil, "", "a" * 39, "a" * 41, "g" * 40 ].each do |value|
        revision = DraftReviewRevision.new \
          prototype:,
          tree_sha: "a" * 40,
          base_commit_sha: "b" * 40
        revision[field] = value

        assert_not revision.valid?, "#{field}=#{value.inspect} must be rejected"
      end
    end
  end

  test "allows anchored draft roots and flat replies but rejects missing or foreign revision context" do
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    author = users.create
    root = ReviewComment.create! \
      prototype:, draft_review_revision: revision, user: author, body: "Draft", anchor: valid_anchor
    reply = root.thread.create_reply!(user: author, body: "Follow-up")

    assert_nil root.build
    assert_nil reply.build
    assert_nil reply.draft_review_revision
    assert_nil reply.anchor
    assert_not ReviewComment.new(prototype:, user: author, body: "No revision", anchor: valid_anchor).valid?
    assert_not ReviewComment.new(prototype:, draft_review_revision: revision, user: author, body: "No anchor").valid?
    other = prototypes.create(repository: prototype.repository, branch_name: "prototype/other")
    assert_not ReviewComment.new(prototype: other, draft_review_revision: revision,
      user: author, body: "Foreign revision", anchor: valid_anchor).valid?
    reply.draft_review_revision = revision
    assert_not reply.valid?
  end

  test "associates matching trees to the actual successful Build once without replacing thread content" do
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    author = users.create
    root = ReviewComment.create! \
      prototype:, draft_review_revision: revision, user: author, body: "Draft", anchor: valid_anchor
    reply = root.thread.create_reply!(user: author, body: "Follow-up")
    thread_attributes = root.reload.attributes.slice("id", "body", "anchor", "root_id", "activity_version")
    build = builds.create_successful(prototype:, number: 7, commit_sha: "c" * 40,
      at: revision.created_at + 1.second)

    build.draft_reviews.associate!(tree_sha: revision.tree_sha)

    assert_equal build, revision.reload.build
    assert_equal build, root.reload.build
    assert_equal thread_attributes, root.attributes.slice("id", "body", "anchor", "root_id", "activity_version")
    assert_equal [ reply.id ], root.replies.reload.ids
    assert_equal "Follow-up", reply.reload.body
    assert_equal root, reply.root
    assert_nil reply.build
    assert_nil reply.draft_review_revision
    later = builds.create_successful(prototype:, number: 9, commit_sha: "d" * 40,
      at: build.finished_at + 1.second)
    later.draft_reviews.associate!(tree_sha: revision.tree_sha)
    build.draft_reviews.associate!(tree_sha: revision.tree_sha)

    assert_equal build, revision.reload.build
    assert_equal build, root.reload.build
  end

  test "does not attach a newly saved revision to an already finished matching Build" do
    prototype = prototypes.create
    build = builds.create_successful(prototype:, at: 1.minute.ago)
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: build.commit_sha

    build.draft_reviews.associate!(tree_sha: revision.tree_sha)

    assert_nil revision.reload.build
  end

  test "accepts an exactly matching completion time" do
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    build = builds.create_successful(prototype:, at: revision.created_at)

    build.draft_reviews.associate!(tree_sha: revision.tree_sha)

    assert_equal build, revision.reload.build
  end

  test "does not attach revisions from another tree or Prototype" do
    prototype = prototypes.create
    other = prototypes.create(repository: prototype.repository, branch_name: "prototype/other")
    wrong_tree = DraftReviewRevision.create! \
      prototype:, tree_sha: "b" * 40, base_commit_sha: "c" * 40
    wrong_prototype = DraftReviewRevision.create! \
      prototype: other, tree_sha: "a" * 40, base_commit_sha: "c" * 40
    build = builds.create_successful(prototype:, at: Time.current + 1.second)

    build.draft_reviews.associate!(tree_sha: "a" * 40)

    assert_nil wrong_tree.reload.build
    assert_nil wrong_prototype.reload.build
  end

  test "failed Builds never claim pending draft revisions" do
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    build = builds.create(prototype:, state: "failed", started_at: Time.current,
      finished_at: Time.current + 1.second)

    build.draft_reviews.associate!(tree_sha: revision.tree_sha)

    assert_nil revision.reload.build
  end

  test "successful publication queues exact source verification and the job uses GitHub's commit tree" do
    configuration = github_app_configurations.create_installed
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    build = nil
    assert_enqueued_jobs 1, only: Build::AssociateDraftReviewsJob do
      build = builds.create_successful(prototype:, at: Time.current + 1.second)
    end
    stub_github_installation_token
    request = stub_request(:get, "#{GITHUB_API_URL}/repos/#{prototype.repository.name_with_owner}/commits/#{build.commit_sha}")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(sha: build.commit_sha, commit: { tree: { sha: revision.tree_sha } }))

    build.draft_reviews.fetch!(configuration:)

    assert_requested request
    assert_equal build, revision.reload.build
  end

  test "source verification failures retain drafts rather than using unverified commit data" do
    configuration = github_app_configurations.create_installed
    prototype = prototypes.create
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    build = builds.create_successful(prototype:, at: Time.current + 1.second)
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/#{prototype.repository.name_with_owner}/commits/#{build.commit_sha}")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(sha: "c" * 40, commit: { tree: { sha: revision.tree_sha } }))

    assert_raises(GithubClient::InvalidResponse) { build.draft_reviews.fetch!(configuration:) }

    assert_nil revision.reload.build
  end

  private

  def valid_anchor
    {
      "schemaVersion" => 1,
      "kind" => "element",
      "route" => { "pathname" => "/", "search" => "", "hash" => "" },
      "selector" => "#save",
      "tagName" => "button",
      "accessibleName" => "Save",
      "selectedText" => "",
      "rect" => { "x" => 20, "y" => 30, "width" => 100, "height" => 32 },
      "viewport" => { "width" => 1280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
      "elementOffset" => { "x" => 0.5, "y" => 0.5 }
    }
  end
end
