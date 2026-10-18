require "test_helper"
require "timeout"

class Repository::PrototypeCandidatesTest < ActiveSupport::TestCase
  test "overlaps branch comparisons within four calls and deduplicates heads before caching on the request thread" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    github_app_configurations.create_installed
    user = users.create
    repository = repositories.create
    heads = { "main" => "a" * 40 }
    6.times do |index|
      name = "prototype/branch-#{index}"
      heads[name] = format("%040x", index + 1)
      prototypes.create(repository:, branch_name: name)
    end
    heads["prototype/shared-head"] = heads.fetch("prototype/branch-0")
    prototypes.create(repository:, branch_name: "prototype/shared-head")
    prototypes.create(repository:, branch_name: "prototype/deleted")
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/#{repository.github_path}/branches")
      .with(query: { "per_page" => "100", "page" => "1" })
      .to_return \
        status: 200,
        body: JSON.generate(heads.map { |name, sha| { name:, commit: { sha: } } }),
        headers: { "Content-Type" => "application/json" }
    started = Queue.new
    release = Queue.new
    mutex = Mutex.new
    active = 0
    maximum = 0
    stub_request(:get, %r{/repos/#{repository.github_path}/compare/})
      .to_return do
        mutex.synchronize do
          active += 1
          maximum = [ maximum, active ].max
        end
        started << true
        release.pop
        {
          status: 200,
          body: JSON.generate(total_commits: 1, commits: [ { author: { id: user.github_id } } ]),
          headers: { "Content-Type" => "application/json" }
        }
      ensure
        mutex.synchronize { active -= 1 }
      end
    coordinator = Thread.new do
      Timeout.timeout(5) do
        4.times { started.pop }
        4.times { release << true }
        2.times { started.pop }
        2.times { release << true }
      end
    ensure
      6.times { release << true }
    end
    request_thread = Thread.current
    configuration_reads = []
    cache_writers = []
    sql = ->(*arguments) do
      payload = arguments.last
      configuration_reads << Thread.current if payload[:sql].include?('FROM "github_app_configurations"')
    end
    cache = ->(*) { cache_writers << Thread.current }
    result = nil

    ActiveSupport::Notifications.subscribed(sql, "sql.active_record") do
      ActiveSupport::Notifications.subscribed(cache, "cache_write.active_support") do
        result = repository.prototype_candidates.available_page(user, permission: "write")
      end
    end
    coordinator.value

    assert_equal heads.keys.grep(/^prototype/).sort, result.first.map(&:branch_name).sort
    assert_equal 1, result.last
    assert_equal 4, maximum
    assert_equal [ request_thread ], configuration_reads
    assert_equal [ request_thread ] * 6, cache_writers
    assert_requested :get, %r{/compare/}, times: 6
    assert_requested :post, "#{GITHUB_API_URL}/app/installations/456/access_tokens", times: 1
    WebMock.reset_executed_requests!

    assert_equal result, repository.prototype_candidates.available_page(user, permission: "write")
    assert_not_requested :get, %r{/compare/}
  ensure
    6.times { release << true } if release
    coordinator&.join
    Rails.cache = original_cache
  end
end
