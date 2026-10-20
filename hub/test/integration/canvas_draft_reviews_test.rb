require "test_helper"

class CanvasDraftReviewsTest < ActionDispatch::IntegrationTest
  setup do
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    stub_github_sign_in \
      repositories: [ repository_payload(2001, "github/prototype") ],
      permissions: { 2001 => "pull" }
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    @repository = Repository.find_by!(github_id: 2001)
    @viewer = User.find_by!(github_id: 1001)
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    @grant = CanvasGrant.create! \
      repository: @repository,
      user: @viewer,
      token_digest: Digest::SHA256.hexdigest(token),
      expires_at: 7.days.from_now
    @headers = { "Authorization" => "Bearer #{token}" }
    @revision_path = "/api/canvas/draft_revision"
  end

  test "readers can sync an unpublished revision without registering or publishing its branch" do
    attributes = { branch: "prototype/unpublished", tree_sha: "a" * 40, base_commit_sha: "b" * 40 }

    assert_difference "Prototype.count", 1 do
      assert_no_difference "Build.count" do
        post @revision_path, params: attributes, headers: @headers, as: :json
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)
    prototype = @repository.prototypes.find(payload.fetch("prototypeId"))
    assert_nil prototype.registered_at
    assert prototype.reviewable?
    assert_equal attributes.fetch(:branch), prototype.branch_name
    assert_nil payload.fetch("buildNumber")
    assert_equal attributes.fetch(:tree_sha), payload.fetch("treeSha")
    assert_equal attributes.fetch(:base_commit_sha), payload.fetch("baseCommitSha")
    assert_equal prototype, DraftReviewRevision.find(payload.fetch("id")).prototype

    assert_no_difference [ "Prototype.count", "DraftReviewRevision.count", "Build.count" ] do
      post @revision_path, params: attributes, headers: @headers, as: :json
    end
    assert_response :success
    assert_equal payload, JSON.parse(response.body)
  end

  test "retired branch history is not revived or replaced by draft sync" do
    retired = prototypes.create(repository: @repository, branch_deleted_at: 1.day.ago,
      retired_head_sha: "c" * 40)

    assert_no_difference [ "Prototype.count", "DraftReviewRevision.count", "Build.count" ] do
      post @revision_path,
        params: { branch: retired.branch_name, tree_sha: "a" * 40, base_commit_sha: "b" * 40 },
        headers: @headers, as: :json
    end

    assert_response :not_found
    assert_not_nil retired.reload.branch_deleted_at
    assert_equal "c" * 40, retired.retired_head_sha

    active = prototypes.create(repository: @repository, branch_name: retired.branch_name)
    assert_no_difference "Prototype.count" do
      post @revision_path,
        params: { branch: active.branch_name, tree_sha: "a" * 40, base_commit_sha: "b" * 40 },
        headers: @headers, as: :json
    end
    assert_response :success
    assert_equal active.id, JSON.parse(response.body).fetch("prototypeId")
    assert_not_nil retired.reload.branch_deleted_at
  end

  test "revision preparation rejects structured source parameters without creating storage" do
    attributes = { branch: "prototype/unpublished", tree_sha: "a" * 40, base_commit_sha: "b" * 40 }

    attributes.each_key do |attribute|
      assert_no_difference [ "Prototype.count", "DraftReviewRevision.count" ] do
        post @revision_path, params: attributes.merge(attribute => [ "invalid" ]),
          headers: @headers, as: :json
      end
      assert_response :bad_request
    end
  end

  test "draft sync still checks current repository read access and the canvas grant" do
    attributes = { branch: "prototype/unpublished", tree_sha: "a" * 40, base_commit_sha: "b" * 40 }
    stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => nil })

    assert_no_difference [ "Prototype.count", "DraftReviewRevision.count" ] do
      post @revision_path, params: attributes, headers: @headers, as: :json
    end
    assert_response :forbidden

    @grant.revoke!
    assert_no_difference [ "Prototype.count", "DraftReviewRevision.count" ] do
      post @revision_path, params: attributes, headers: @headers, as: :json
    end
    assert_response :unauthorized
  end

  test "default and workflow installation branches do not become draft review Prototypes" do
    [ @repository.default_branch, "replica/install-workflow" ].each do |branch|
      assert_no_difference [ "Prototype.count", "DraftReviewRevision.count" ] do
        post @revision_path,
          params: { branch:, tree_sha: "a" * 40, base_commit_sha: "b" * 40 },
          headers: @headers, as: :json
      end

      assert_response :not_found
    end
  end

  test "an unpublished root and reply are stored immediately without a Build or owner notifications" do
    owner = users.create(github_id: 1002, login: "mona")
    prototype = prototypes.create(repository: @repository, author: owner)
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    path = canvas_api_review_comments_path(@repository.route_id, prototype)

    assert_no_difference [ "Build.count", "Notification.count" ] do
      post path, params: { review_comment: {
        draft_revision_id: revision.id, body: "Unpublished feedback", anchor: valid_anchor
      } }, headers: @headers, as: :json

      assert_response :created
      root = prototype.review_comments.roots.sole
      assert_equal revision, root.draft_review_revision
      assert_nil root.build
      assert_equal "Unpublished feedback", root.body
      assert_equal root.id, JSON.parse(response.body).fetch("comments").first.fetch("id")

      post "#{path}/#{root.id}/replies",
        params: { review_comment: { body: "Immediate reply" } },
        headers: @headers, as: :json

      assert_response :created
      reply = root.replies.sole
      assert_equal "Immediate reply", reply.body
      assert_nil reply.build
      assert_nil reply.draft_review_revision
    end
  end

  test "only the selected revision joins published comments and neither draft roots nor replies leak into feeds" do
    prototype = prototypes.create(repository: @repository)
    build = builds.create_successful(prototype:)
    published = ReviewComment.create! \
      prototype:, build:, user: @viewer, body: "Published feedback", anchor: valid_anchor
    selected = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: build.commit_sha
    unrelated = DraftReviewRevision.create! \
      prototype:, tree_sha: "b" * 40, base_commit_sha: build.commit_sha
    root = ReviewComment.create! \
      prototype:, draft_review_revision: selected, user: @viewer, body: "Selected draft", anchor: valid_anchor
    reply = root.thread.create_reply!(user: @viewer, body: "Selected reply")
    other_root = ReviewComment.create! \
      prototype:, draft_review_revision: unrelated, user: @viewer, body: "Other draft", anchor: valid_anchor
    other_reply = other_root.thread.create_reply!(user: @viewer, body: "Other reply")
    path = canvas_api_review_comments_path(@repository.route_id, prototype)

    get path, params: { draft_revision_id: selected.id }, headers: @headers

    assert_response :success
    assert_equal [ published.id, root.id, reply.id ].sort, response_comment_ids.sort
    get path, params: { draft_revision_id: unrelated.id }, headers: @headers
    assert_response :success
    assert_equal [ published.id, other_root.id, other_reply.id ].sort, response_comment_ids.sort

    [
      path,
      canvas_api_repository_review_comments_path(@repository.route_id),
      canvas_api_repository_review_comment_summaries_path(@repository.route_id)
    ].each do |feed|
      get feed, headers: @headers

      assert_response :success
      assert_equal [ published.id ], response_comment_ids
    end
    browser_path = repository_prototype_review_comments_path(@repository.route_id, prototype)
    get browser_path, params: { draft_revision_id: selected.id }
    assert_response :success
    assert_equal [ published.id ], response_comment_ids

    matching = builds.create_successful(prototype:, number: 7, commit_sha: "c" * 40,
      at: selected.created_at + 1.second)
    matching.draft_reviews.associate!(tree_sha: selected.tree_sha)

    [
      [ path, @headers ],
      [ canvas_api_repository_review_comments_path(@repository.route_id), @headers ],
      [ browser_path, {} ]
    ].each do |feed, headers|
      get feed, headers: headers

      assert_response :success
      assert_equal [ published.id, root.id, reply.id ].sort, response_comment_ids.sort
    end
    get canvas_api_repository_review_comment_summaries_path(@repository.route_id), headers: @headers
    assert_response :success
    assert_equal [ published.id, root.id ].sort, response_comment_ids.sort
  end

  test "draft creation cannot mix targets or reference another Prototype revision" do
    prototype = prototypes.create(repository: @repository)
    build = builds.create_successful(prototype:)
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: build.commit_sha
    other = prototypes.create(repository: @repository, branch_name: "prototype/other")
    path = canvas_api_review_comments_path(@repository.route_id, prototype)
    attributes = { draft_revision_id: revision.id, build_number: build.number,
      body: "Ambiguous target", anchor: valid_anchor }

    assert_no_difference "ReviewComment.count" do
      post path, params: { review_comment: attributes }, headers: @headers, as: :json
    end
    assert_response :bad_request

    assert_no_difference "ReviewComment.count" do
      post canvas_api_review_comments_path(@repository.route_id, other),
        params: { review_comment: attributes.except(:build_number) },
        headers: @headers, as: :json
    end
    assert_response :not_found

    get canvas_api_review_comments_path(@repository.route_id, other),
      params: { draft_revision_id: revision.id }, headers: @headers
    assert_response :not_found
  end

  test "new comments on an associated revision use its real Build rather than the latest number" do
    prototype = prototypes.create(repository: @repository)
    revision = DraftReviewRevision.create! \
      prototype:, tree_sha: "a" * 40, base_commit_sha: "b" * 40
    matching = builds.create_successful(prototype:, number: 7, commit_sha: "c" * 40,
      at: revision.created_at + 1.second)
    matching.draft_reviews.associate!(tree_sha: revision.tree_sha)
    builds.create_successful(prototype:, number: 11, commit_sha: "d" * 40,
      at: revision.created_at + 2.seconds)

    post canvas_api_review_comments_path(@repository.route_id, prototype),
      params: { review_comment: {
        draft_revision_id: revision.id, body: "Matching revision", anchor: valid_anchor
      } }, headers: @headers, as: :json

    assert_response :created
    root = prototype.review_comments.roots.sole
    assert_equal matching, root.build
    assert_equal revision, root.draft_review_revision
    assert_equal 7, JSON.parse(response.body).fetch("comments").first.fetch("buildNumber")

    post @revision_path,
      params: { branch: prototype.branch_name, tree_sha: revision.tree_sha, base_commit_sha: revision.base_commit_sha },
      headers: @headers, as: :json

    assert_response :success
    assert_equal revision.id, JSON.parse(response.body).fetch("id")
    assert_equal 7, JSON.parse(response.body).fetch("buildNumber")
  end

  private

  def response_comment_ids
    JSON.parse(response.body).fetch("comments").pluck("id")
  end

  def valid_anchor
    {
      "schemaVersion" => 1,
      "kind" => "element",
      "route" => { "pathname" => "/", "search" => "", "hash" => "" },
      "selector" => "#save",
      "accessibleName" => "Save",
      "tagName" => "button",
      "selectedText" => "",
      "rect" => { "x" => 20, "y" => 30, "width" => 100, "height" => 32 },
      "viewport" => { "width" => 1280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
      "elementOffset" => { "x" => 0.5, "y" => 0.5 }
    }
  end
end
