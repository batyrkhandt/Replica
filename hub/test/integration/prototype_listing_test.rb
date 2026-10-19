require "test_helper"
require "fileutils"
require "open3"

class PrototypeListingTest < ActionDispatch::IntegrationTest
  setup do
    github_app_configurations.create_installed
  end

  test "returns at most 24 registered reviewable prototypes in stable registration order" do
    repository, user = sign_in_repository
    time = Time.current.change(usec: 123456)
    older = registered_prototype(repository, author: user, at: time - 1.day)
    tied = 25.times.map { registered_prototype(repository, author: user, at: time) }
    prototypes.create(repository:, branch_name: "prototype/unregistered", author: user)
    prototypes.create(repository:, branch_name: repository.default_branch)
    prototypes.create(repository:, branch_name: "replica/install-workflow")
    retired = registered_prototype(repository, author: user)
    retired.update!(branch_deleted_at: Time.current)
    foreign = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    registered_prototype(foreign, author: user)
    older.update!(description: "Edited after the newer registrations")

    data = listing(repository)

    assert_equal tied.reverse.first(24).map { _1.id.to_s }, data.fetch("prototypes").pluck("id")
    metadata = data.fetch("listing")
    assert_equal "", metadata.fetch("query")
    assert_equal "", metadata.fetch("author")
    assert_kind_of String, metadata.fetch("authorLabel")
    assert_equal 26, metadata.fetch("matchingCount")
    assert_equal 26, metadata.fetch("totalCount")
    assert_nil metadata.fetch("previousPath")
    assert_nil metadata.fetch("newestPath")
    assert_kind_of String, metadata.fetch("nextPath")
    assert_equal authors_path(repository), metadata.fetch("authorsPath")
  end

  test "filters the full collection before limiting and preserves filters going next and previous" do
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
    assert_equal 75, first.fetch("listing").fetch("totalCount")

    next_path = first.fetch("listing").fetch("nextPath")
    assert_filters next_path, q: "nEeDlE", author: user.id.to_s
    second = listing_at(next_path)
    assert_equal expected.slice(24, 24), second.fetch("prototypes").pluck("id")
    assert_equal 49, second.fetch("listing").fetch("matchingCount")
    assert_filters second.fetch("listing").fetch("newestPath"), q: "nEeDlE", author: user.id.to_s
    previous_path = second.fetch("listing").fetch("previousPath")
    assert_filters previous_path, q: "nEeDlE", author: user.id.to_s
    previous = listing_at(previous_path)
    assert_equal expected.first(24), previous.fetch("prototypes").pluck("id")
    assert_nil previous.fetch("listing").fetch("previousPath")

    third = listing_at(second.fetch("listing").fetch("nextPath"))
    assert_equal expected.last(1), third.fetch("prototypes").pluck("id")
    assert_nil third.fetch("listing").fetch("nextPath")
    assert_equal expected.first(24),
      listing_at(third.fetch("listing").fetch("newestPath")).fetch("prototypes").pluck("id")
  end

  test "new registrations between next requests do not repeat visited prototypes" do
    repository, user = sign_in_repository
    time = Time.current
    originals = 50.times.map { registered_prototype(repository, author: user, at: time) }
    first = listing(repository)
    registered_prototype(repository, author: user, at: time + 1.second)

    second = listing_at(first.fetch("listing").fetch("nextPath"))
    third = listing_at(second.fetch("listing").fetch("nextPath"))

    visited = [ first, second, third ].flat_map { _1.fetch("prototypes").pluck("id") }
    assert_equal originals.reverse.map { _1.id.to_s }, visited
    assert_equal 51, second.fetch("listing").fetch("matchingCount")
    assert_nil third.fetch("listing").fetch("nextPath")
  end

  test "hydrates only the selected page and its Builds rather than the full gallery" do
    repository, user = sign_in_repository
    time = Time.current
    records = 60.times.map do |index|
      prototype = registered_prototype(repository, author: user, at: time)
      builds.create_successful(prototype:, number: 1)
      latest = builds.create(prototype:, number: 2, commit_sha: "b" * 40)
      prototype.update!(current_build: latest) if index.even?
      prototype
    end
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
    assert_equal 60, data.fetch("listing").fetch("totalCount")
    cards.each do |card|
      assert_equal "queued", card.fetch("latestBuild").fetch("state")
      assert_equal 1, card.fetch("reviewBuild").fetch("number")
    end
    assert_operator instantiated.fetch("Prototype"), :<=, 25
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
    assert_equal 5, data.fetch("listing").fetch("matchingCount")
    assert_equal 6, data.fetch("listing").fetch("totalCount")
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
    other = create_author("registrant", name: "Registration Author", avatar_url: "https://avatars.example.test/registrant")
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
    assert_equal other.avatar_url, author.fetch("avatarUrl")
    unknown_author = cards.fetch(unknown.id.to_s).fetch("author")
    assert_equal I18n.t("repositories.show.unknown_author"), unknown_author.fetch("ownerLabel")
    assert_nil unknown_author.fetch("url")
    assert_nil unknown_author.fetch("avatarUrl")

    me = listing(repository, author: "me")
    assert_equal [ mine.id.to_s ], me.fetch("prototypes").pluck("id")
    assert_equal "me", me.fetch("listing").fetch("author")
    assert_equal 1, me.fetch("listing").fetch("matchingCount")
    assert_equal 3, me.fetch("listing").fetch("totalCount")
    named = listing(repository, author: other.id.to_s)
    assert_equal [ theirs.id.to_s ], named.fetch("prototypes").pluck("id")
    assert_equal other.id.to_s, named.fetch("listing").fetch("author")
    assert_includes named.fetch("listing").fetch("authorLabel"), other.login
    assert_equal 3, all.fetch("prototypes").size
  end

  test "a stale valid cursor returns an empty filtered page with a route back to newest" do
    repository, user = sign_in_repository
    originals = 25.times.map { registered_prototype(repository, author: user, name: "Needle") }
    first = listing(repository, q: "Needle", author: "me")
    originals.first.update!(branch_deleted_at: Time.current)

    stale = listing_at(first.fetch("listing").fetch("nextPath"))

    assert_empty stale.fetch("prototypes")
    assert_equal 24, stale.fetch("listing").fetch("matchingCount")
    assert_equal 24, stale.fetch("listing").fetch("totalCount")
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
      { q: "x" * 201 }, { q: [ "query" ] }, { q: { value: "query" } },
      { author: [ "me" ] }, { author: { id: user.id } }, { author: "0" },
      { author: "-1" }, { author: "1.5" }, { author: "#{user.id}suffix" },
      { author: "someone" }, { cursor: "not-a-signed-cursor" }, { cursor: [ "cursor" ] }
    ].each do |params|
      get repository_path(repository.github_id), params:, headers: json_headers
      assert_response :bad_request, params.inspect
    end

    accepted = listing(repository, q: "x" * 200)
    assert_equal "x" * 200, accepted.fetch("listing").fetch("query")
    assert_empty accepted.fetch("prototypes")
  end

  test "prototype cursors cannot be tampered with or reused for another repository filter or user" do
    repository, user = sign_in_repository
    25.times { registered_prototype(repository, author: user, name: "Needle") }
    first = listing(repository, q: "Needle", author: "me")
    path = first.fetch("listing").fetch("nextPath")
    params = Rack::Utils.parse_query(URI.parse(path).query)
    cursor_key = (params.keys - %w[q author]).sole
    other_repository = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })

    [
      [ repository, params.merge(cursor_key => "#{params.fetch(cursor_key)}tampered") ],
      [ repository, params.merge("q" => "Different") ],
      [ repository, params.merge("author" => user.id.to_s) ],
      [ other_repository, params ]
    ].each do |target, query|
      get repository_path(target.github_id), params: query, headers: json_headers
      assert_response :bad_request
    end

    sign_in_as_another_reader
    get path, headers: json_headers
    assert_response :bad_request
  end

  test "author lookup is distinct bounded and includes registrants outside the loaded prototype page" do
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
    assert_kind_of String, first.fetch("nextCursor")

    second = author_lookup(repository, cursor: first.fetch("nextCursor"))
    assert_equal expected.last(2).map { _1.id.to_s }, second.fetch("authors").pluck("id")
    assert_nil second.fetch("nextCursor")
    assert_equal 22, (first.fetch("authors") + second.fetch("authors")).pluck("id").uniq.size
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

  test "author continuations remain stable when an author is inserted before the cursor" do
    repository, = sign_in_repository
    authors = 21.times.map do |index|
      author = create_author("owner-#{index.to_s.rjust(2, '0')}")
      registered_prototype(repository, author:)
      author
    end
    first = author_lookup(repository)
    registered_prototype(repository, author: create_author("aaa-new-owner"))

    second = author_lookup(repository, cursor: first.fetch("nextCursor"))

    assert_equal [ authors.last.id.to_s ], second.fetch("authors").pluck("id")
    assert_nil second.fetch("nextCursor")
  end

  test "author lookup validates query shapes length and signed cursor scope" do
    repository, = sign_in_repository
    21.times do |index|
      registered_prototype(repository, author: create_author("needle-#{index.to_s.rjust(2, '0')}"))
    end
    other_repository = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    first = author_lookup(repository, q: "needle")
    cursor = first.fetch("nextCursor")
    assert_kind_of String, cursor

    [
      { q: "x" * 201 }, { q: [ "needle" ] }, { q: { value: "needle" } },
      { cursor: [ cursor ] }, { cursor: "invalid" },
      { cursor: "#{cursor}tampered", q: "needle" }, { cursor:, q: "another" }
    ].each do |params|
      get authors_path(repository), params:, headers: json_headers
      assert_response :bad_request, params.inspect
    end
    get authors_path(other_repository), params: { cursor:, q: "needle" }, headers: json_headers
    assert_response :bad_request
    assert_empty author_lookup(repository, q: "x" * 200).fetch("authors")

    sign_in_as_another_reader
    get authors_path(repository), params: { cursor:, q: "needle" }, headers: json_headers
    assert_response :bad_request
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

  test "local cards retain the local identity while author filtering uses saved registration authors" do
    root = Rails.root.join("storage", "listing-local-test-#{SecureRandom.hex(6)}")
    checkout = root.join("one")
    original_enabled = LocalDevelopment.method(:enabled?)
    original_root = LocalDevelopment.method(:repositories_root)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    LocalDevelopment.define_singleton_method(:repositories_root) { root }
    FileUtils.mkdir_p(checkout)
    [
      [ "init", "-b", "main" ],
      [ "-c", "user.name=Local Test", "-c", "user.email=local@example.invalid",
        "commit", "--allow-empty", "-m", "Initial" ]
    ].each do |arguments|
      _, error, status = Open3.capture3("git", "-C", checkout.to_s, *arguments)
      assert status.success?, error
    end
    host! "replica.localhost:19500"
    post local_authentication_path
    assert_redirected_to welcome_path
    repository = Repository.find_by!(local_path: checkout.to_s)
    user = User.find_by!(github_id: nil)
    other = create_author("saved-registrant")
    mine = registered_prototype(repository, author: user)
    theirs = registered_prototype(repository, author: other)
    unknown = registered_prototype(repository)

    all = listing(repository)
    assert_equal [ mine, theirs, unknown ].map { _1.id.to_s }.sort,
      all.fetch("prototypes").pluck("id").sort
    all.fetch("prototypes").each do |card|
      assert_equal "@#{user.login}", card.fetch("author").fetch("ownerLabel")
      assert_equal User::LOCAL_AVATAR_URL, card.fetch("author").fetch("avatarUrl")
      assert_nil card.fetch("author").fetch("url")
    end
    assert_equal [ mine.id.to_s ], listing(repository, author: "me").fetch("prototypes").pluck("id")
    assert_equal [ theirs.id.to_s ],
      listing(repository, author: other.id.to_s).fetch("prototypes").pluck("id")
    assert_equal [ other.id.to_s ], author_lookup(repository).fetch("authors").pluck("id")
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original_enabled) if original_enabled
    LocalDevelopment.define_singleton_method(:repositories_root, original_root) if original_root
    FileUtils.rm_rf(root) if root
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

  def create_author(login, name: nil, avatar_url: nil)
    users.create(github_id: User.maximum(:github_id).to_i + 1, login:, name:, avatar_url:)
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
    assert_kind_of String, path
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
    assert_kind_of String, path
    params = Rack::Utils.parse_query(URI.parse(path).query)
    assert_equal q, params.fetch("q")
    assert_equal author, params.fetch("author")
  end

  def json_headers
    { "Accept" => "application/json" }
  end
end
