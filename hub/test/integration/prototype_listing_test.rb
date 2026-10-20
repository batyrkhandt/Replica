require "test_helper"

class PrototypeListingTest < ActionDispatch::IntegrationTest
  setup do
    github_app_configurations.create_installed
  end

  test "filters before paging and preserves stable continuations when a prototype is registered" do
    repository, user = sign_in_repository
    other = create_author("other-reviewer")
    time = Time.current
    matching = 49.times.map do |index|
      registered_prototype(repository, author: user, name: "Needle #{index}", at: time - 1.day)
    end
    25.times { registered_prototype(repository, author: other, name: "Needle", at: time) }
    registered_prototype(repository, author: user, name: "Unrelated", at: time)
    expected = matching.reverse.map { _1.id.to_s }

    first = listing(repository, q: "nEeDlE", author: user.id.to_s)
    assert_equal expected.first(24), first.fetch("prototypes").pluck("id")
    assert_equal 49, first.fetch("listing").fetch("matchingCount")
    assert_nil first.fetch("listing").fetch("previousPath")
    newest = registered_prototype(repository, author: user, name: "Needle added", at: time + 1.second)

    next_path = first.fetch("listing").fetch("nextPath")
    assert_filters next_path, q: "nEeDlE", author: user.id.to_s
    second = listing_at(next_path)
    assert_equal expected.slice(24, 24), second.fetch("prototypes").pluck("id")
    assert_equal 50, second.fetch("listing").fetch("matchingCount")
    assert_filters second.fetch("listing").fetch("newestPath"), q: "nEeDlE", author: user.id.to_s
    previous_path = second.fetch("listing").fetch("previousPath")
    assert_filters previous_path, q: "nEeDlE", author: user.id.to_s
    previous = listing_at(previous_path)
    assert_equal expected.first(24), previous.fetch("prototypes").pluck("id")
    third = listing_at(second.fetch("listing").fetch("nextPath"))
    assert_equal expected.last(1), third.fetch("prototypes").pluck("id")
    assert_nil third.fetch("listing").fetch("nextPath")
    assert_equal [ newest.id.to_s, *expected ].first(24),
      listing_at(third.fetch("listing").fetch("newestPath")).fetch("prototypes").pluck("id")
  end

  test "selects only eligible prototypes and bounds card and Build hydration to 24 results" do
    repository, user = sign_in_repository
    time = Time.current
    records = 60.times.map do |index|
      prototype = registered_prototype(repository, author: user, at: time)
      builds.create_successful(prototype:, number: 1)
      latest = builds.create(prototype:, number: 2, commit_sha: "b" * 40)
      prototype.update!(current_build: latest) if index.even?
      prototype
    end
    prototypes.create(repository:, branch_name: "prototype/unregistered", author: user)
    prototypes.create(repository:, branch_name: repository.default_branch)
    prototypes.create(repository:, branch_name: "replica/install-workflow")
    retired = registered_prototype(repository, author: user)
    retired.update!(branch_deleted_at: Time.current)
    foreign = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    registered_prototype(foreign, author: user)
    instantiated = Hash.new(0)
    subscriber = lambda do |*arguments|
      payload = arguments.last
      instantiated[payload.fetch(:class_name)] += payload.fetch(:record_count)
    end
    data = nil

    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      data = listing(repository)
    end

    cards = data.fetch("prototypes")
    assert_equal records.reverse.first(24).map { _1.id.to_s }, cards.pluck("id")
    assert_equal 60, data.fetch("listing").fetch("matchingCount")
    cards.each do |card|
      assert_equal "queued", card.fetch("latestBuild").fetch("state")
      assert_equal 1, card.fetch("reviewBuild").fetch("number")
    end
    assert_operator instantiated.fetch("Prototype"), :<=, 24
    assert_operator instantiated.fetch("Build"), :<=, 24 * 2
  end

  test "searches names descriptions branches and registration author login and name case insensitively" do
    repository, user = sign_in_repository
    by_login = create_author("needle-owner", name: "Another person")
    by_name = create_author("name-owner", name: "Needle Person")
    matches = [
      registered_prototype(repository, author: user, name: "A NEEDLE design"),
      registered_prototype(repository, author: user, description: "A Needle description"),
      registered_prototype(repository, author: user, branch_name: "prototype/needle-branch"),
      registered_prototype(repository, author: by_login),
      registered_prototype(repository, author: by_name)
    ]
    unrelated = registered_prototype(repository, author: user)
    build = builds.create(prototype: unrelated)
    build.commit_author.record! \
      "sha" => build.commit_sha,
      "commit" => { "author" => { "name" => "Needle Committer" } },
      "author" => { "id" => 9001, "login" => "needle-committer", "avatar_url" => nil }

    data = listing(repository, q: "nEeDlE")

    assert_equal matches.map { _1.id.to_s }.sort, data.fetch("prototypes").pluck("id").sort
  end

  test "treats percent underscore and backslash as literal search characters" do
    repository, user = sign_in_repository
    literal = registered_prototype(repository, author: user, name: '100%_done\path')
    registered_prototype(repository, author: user, name: "100XXdonepath")

    [ "%", "_", "\\" ].each do |query|
      data = listing(repository, q: query)
      assert_equal [ literal.id.to_s ], data.fetch("prototypes").pluck("id"), query
    end
  end

  test "author filters and card attribution use the saved registrant rather than the commit author" do
    repository, user = sign_in_repository
    other = create_author("registrant")
    mine = registered_prototype(repository, author: user)
    theirs = registered_prototype(repository, author: other)
    unknown = registered_prototype(repository)
    [ theirs, unknown ].each do |prototype|
      build = builds.create(prototype:)
      build.commit_author.record! \
        "sha" => build.commit_sha,
        "commit" => { "author" => { "name" => "Octocat" } },
        "author" => { "id" => user.github_id, "login" => user.login, "avatar_url" => user.avatar_url }
    end

    all = listing(repository)
    cards = all.fetch("prototypes").index_by { _1.fetch("id") }
    author = cards.fetch(theirs.id.to_s).fetch("author")
    assert_equal "@registrant", author.fetch("ownerLabel")
    assert_equal "https://github.com/registrant", author.fetch("url")
    unknown_author = cards.fetch(unknown.id.to_s).fetch("author")
    assert_equal I18n.t("repositories.show.unknown_author"), unknown_author.fetch("ownerLabel")
    assert_nil unknown_author.fetch("url")

    me = listing(repository, author: "me")
    assert_equal [ mine.id.to_s ], me.fetch("prototypes").pluck("id")
    named = listing(repository, author: other.id.to_s)
    assert_equal [ theirs.id.to_s ], named.fetch("prototypes").pluck("id")
    assert_includes named.fetch("listing").fetch("authorLabel"), other.login
  end

  test "a stale valid cursor returns an empty filtered page with a route back to newest" do
    repository, user = sign_in_repository
    originals = 25.times.map { registered_prototype(repository, author: user, name: "Needle") }
    first = listing(repository, q: "Needle", author: "me")
    originals.first.update!(branch_deleted_at: Time.current)

    stale = listing_at(first.fetch("listing").fetch("nextPath"))

    assert_empty stale.fetch("prototypes")
    assert_equal 24, stale.fetch("listing").fetch("matchingCount")
    newest_path = stale.fetch("listing").fetch("newestPath")
    assert_filters newest_path, q: "Needle", author: "me"
    newest = listing_at(newest_path)
    assert_equal 24, newest.fetch("prototypes").size
    assert_nil newest.fetch("listing").fetch("nextPath")
  end

  test "rejects malformed filters and cursors instead of silently returning an unfiltered collection" do
    repository, user = sign_in_repository
    registered_prototype(repository, author: user)

    [
      { q: "x" * 201 }, { q: [ "query" ] }, { author: "0" },
      { cursor: "not-a-signed-cursor" }, { cursor: [ "cursor" ] }
    ].each do |params|
      get repository_path(repository.github_id), params:, headers: json_headers
      assert_response :bad_request, params.inspect
    end

    accepted = listing(repository, q: "x" * 200)
    assert_equal "x" * 200, accepted.fetch("listing").fetch("query")
  end

  test "both cursor types reject tampering and changes to repository filter or viewer" do
    repository, user = sign_in_repository
    25.times do |index|
      registered_prototype(repository, author: create_author("needle-#{index}"), name: "Needle")
    end
    first = listing(repository, q: "Needle")
    path = first.fetch("listing").fetch("nextPath")
    params = Rack::Utils.parse_query(URI.parse(path).query)
    other_repository = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    endpoints = [
      [ repository_path(repository.github_id), repository_path(other_repository.github_id), params ],
      [ authors_path(repository), authors_path(other_repository),
        { "q" => "needle", "cursor" => author_lookup(repository, q: "needle").fetch("nextCursor") } ]
    ]

    endpoints.each do |endpoint, foreign_endpoint, query|
      [ query.merge("cursor" => "#{query.fetch('cursor')}tampered"),
        query.merge("q" => "Different") ].each do |invalid|
        get endpoint, params: invalid, headers: json_headers
        assert_response :bad_request
      end
      get foreign_endpoint, params: query, headers: json_headers
      assert_response :bad_request
    end
    get repository_path(repository.github_id), params: params.merge("author" => user.id.to_s), headers: json_headers
    assert_response :bad_request

    sign_in_as_another_reader
    endpoints.each do |endpoint, _, query|
      get endpoint, params: query, headers: json_headers
      assert_response :bad_request
    end
  end

  test "pages distinct registrants outside the loaded page without shifting for new authors" do
    repository, user = sign_in_repository
    time = Time.current
    authors = 22.times.map do |index|
      login = index < 2 ? "contributor-00" : "contributor-#{index.to_s.rjust(2, '0')}"
      author = create_author(login, name: index.zero? ? nil : "Contributor #{index}")
      registered_prototype(repository, author:, at: time - 1.day)
      author
    end
    25.times { registered_prototype(repository, author: authors.first, at: time) }
    registered_prototype(repository, author: user, at: time)
    registered_prototype(repository, at: time)
    first = author_lookup(repository)
    expected = authors.sort_by { [ _1.login, _1.id ] }
    assert_equal expected.first(20).map { _1.id.to_s }, first.fetch("authors").pluck("id")
    expected_author = {
      "id" => authors.first.id.to_s, "login" => authors.first.login, "name" => nil, "avatarUrl" => nil
    }
    assert_equal expected_author, first.fetch("authors").first
    registered_prototype(repository, author: create_author("aaa-new-owner"))
    second = author_lookup(repository, cursor: first.fetch("nextCursor"))
    assert_equal expected.last(2).map { _1.id.to_s }, second.fetch("authors").pluck("id")
    assert_nil second.fetch("nextCursor")
  end

  test "author lookup searches literal login and name substrings within eligible repository registrants only" do
    repository, user = sign_in_repository
    by_login = create_author("needle-login")
    by_name = create_author("another-login", name: "A NEEDLE person")
    literal = create_author("literal-owner", name: "100%_Team")
    [ by_login, by_name, literal ].each { registered_prototype(repository, author: _1) }
    registered_prototype(repository, author: user)
    registered_prototype(repository)
    hidden = create_author("needle-hidden")
    prototypes.create(repository:, branch_name: "prototype/unregistered", author: hidden)
    prototypes.create(repository:, branch_name: "replica/install-workflow", author: hidden)
    prototypes.create(repository:, branch_name: repository.default_branch, author: hidden)
    retired = registered_prototype(repository, author: hidden)
    retired.update!(branch_deleted_at: Time.current)
    foreign = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    registered_prototype(foreign, author: hidden)
    distractor = create_author("distractor", name: "100XXTeam")
    registered_prototype(repository, author: distractor)

    result = author_lookup(repository, q: "nEeDlE")
    assert_equal [ by_login.id.to_s, by_name.id.to_s ].sort, result.fetch("authors").pluck("id").sort
    [ "%", "_" ].each do |query|
      assert_equal [ literal.id.to_s ], author_lookup(repository, q: query).fetch("authors").pluck("id")
    end
    assert_equal [ by_login, by_name, literal, distractor ].map { _1.id.to_s }.sort,
      author_lookup(repository).fetch("authors").pluck("id").sort
  end

  test "both listing endpoints require a signed in repository reader and fail closed on permission errors" do
    visible = repository_payload(2001, "github/prototype")
    denied = repository_payload(2002, "github/private")
    failing = repository_payload(2003, "github/unavailable")
    stub_github_sign_in \
      repositories: [ visible, denied, failing ],
      permissions: { 2001 => "pull", 2002 => nil, 2003 => :failure }
    sign_in_to_hub
    [ [ 2002, :not_found ], [ 2003, :service_unavailable ] ].each do |github_id, status|
      [ "/repositories/#{github_id}", "/repositories/#{github_id}/prototype_authors" ].each do |path|
        get path, headers: json_headers
        assert_response status
      end
    end

    delete session_path
    [ "/repositories/2001", "/repositories/2001/prototype_authors" ].each do |path|
      get path, headers: json_headers
      assert_redirected_to root_path
    end
  end

  private

  def sign_in_repository
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "pull" })
    sign_in_to_hub
    [ Repository.find_by!(github_id: 2001), User.find_by!(github_id: 1001) ]
  end

  def sign_in_as_another_reader
    delete session_path
    stub_github_oauth_user(github_id: 1002, login: "another-reader")
    payloads = Repository.where.not(github_id: nil).map { repository_payload(_1.github_id, _1.name_with_owner) }
    stub_github_permissions \
      payloads,
      payloads.to_h { [ _1.fetch("id"), "pull" ] },
      github_id: 1002,
      login: "another-reader"
    sign_in_to_hub(github_id: 1002)
  end

  def create_author(login, name: nil)
    users.create(github_id: User.maximum(:github_id).to_i + 1, login:, name:, avatar_url: nil)
  end

  def registered_prototype(repository, author: nil, name: "Prototype", description: nil,
    branch_name: "prototype/#{SecureRandom.hex(6)}", at: Time.current)
    prototype = prototypes.create(repository:, branch_name:)
    travel_to(at) { prototype.register!(name:, description:, author:) }
    prototype
  end

  def listing(repository, **params)
    listing_at(repository_path(repository.route_id), params:)
  end

  def listing_at(path, params: {})
    get path, params:, headers: json_headers
    assert_response :success
    JSON.parse(response.body).fetch("data")
  end

  def authors_path(repository)
    "/repositories/#{repository.route_id}/prototype_authors"
  end

  def author_lookup(repository, **params)
    get authors_path(repository), params:, headers: json_headers
    assert_response :success
    JSON.parse(response.body)
  end

  def assert_filters(path, q:, author:)
    params = Rack::Utils.parse_query(URI.parse(path).query)
    assert_equal q, params.fetch("q")
    assert_equal author, params.fetch("author")
  end

  def json_headers
    { "Accept" => "application/json" }
  end
end
