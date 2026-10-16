require "yaml"
require "open3"

def check(condition, message)
  abort(message) unless condition
end

def expression(value)
  value.to_s.strip.delete_prefix("${{").delete_suffix("}}").strip
end

root = File.expand_path("..", __dir__)
workflows = %w[hub-ci actions-ci].to_h do |name|
  [name, YAML.safe_load(File.read(File.join(root, ".github/workflows/#{name}.yml"))).fetch("jobs")]
end
expected_gates = {
  ["hub-ci", "frontend_test_shard"] => ["Frontend tests shard ${{ matrix.shard }}/4", ["changes"]],
  ["hub-ci", "frontend_test"] => ["Frontend tests", %w[changes frontend_test_shard frontend_integration_test]],
  ["actions-ci", "result"] => ["Replica action tests", %w[changes test]]
}
gates = {}

workflows.each do |workflow, jobs|
  suite = workflow == "hub-ci" ? "hub" : "build_action"
  selection = "needs.changes.outputs.#{suite} == 'true'"
  jobs.each do |id, job|
    next if id == "changes"

    label = "#{workflow}/#{id}"
    check(Array(job["needs"]).include?("changes"), "#{label}: missing changes dependency")
    steps = job.fetch("steps")
    guards = steps.select { |step| step.fetch("env", {}).key?("SELECTION_RESULT") }
    if guards.empty?
      check(expression(job["if"]) == selection, "#{label}: suite must require selection")
      next
    end

    key = [workflow, id]
    check(expected_gates.key?(key), "#{label}: unexpected gate")
    check(guards.length == 1, "#{label}: expected exactly one selection guard")
    name, needs = expected_gates.fetch(key)
    check(job["name"] == name, "#{label}: required check name changed")
    check(Array(job["needs"]).sort == needs.sort, "#{label}: incorrect gate dependencies")
    check(expression(job["if"]) == "always()", "#{label}: gate must always run")
    guard = guards.first
    check(!guard.key?("if"), "#{label}: guard must not be conditional")
    env = guard.fetch("env")
    check(expression(env["SELECTION_RESULT"]) == "needs.changes.result", "#{label}: incorrect selection result")
    check(expression(env["SELECTED"]) == "needs.changes.outputs.#{suite}", "#{label}: incorrect selection output")
    result_jobs = { "SHARD_RESULT" => "frontend_test_shard", "INTEGRATION_RESULT" => "frontend_integration_test", "TEST_RESULT" => "test" }
    expected_results = id == "frontend_test" ? %w[SHARD_RESULT INTEGRATION_RESULT] : id == "result" ? ["TEST_RESULT"] : []
    check(env.keys.sort == (%w[SELECTION_RESULT SELECTED] + expected_results).sort, "#{label}: incorrect gate inputs")
    expected_results.each do |variable|
      check(expression(env[variable]) == "needs.#{result_jobs.fetch(variable)}.result", "#{label}: incorrect #{variable}")
    end
    if id == "frontend_test_shard"
      check(job.dig("strategy", "matrix", "shard") == [1, 2, 3, 4], "#{label}: required shards changed")
      check(steps.first.equal?(guard) && steps.length > 1, "#{label}: guard must precede suite steps")
      check(steps.drop(1).all? { |step| expression(step["if"]) == selection }, "#{label}: suite steps must require selection")
    end
    gates[key] = guard.fetch("run")
  end
end
check(gates.keys.sort == expected_gates.keys.sort, "Expected exactly the shard guard and both final result gates")
check(workflows.fetch("actions-ci").fetch("test")["name"] == "Build action suite", "Build action suite name changed")

states = %w[success failure cancelled skipped] + [""]
checks = 0
gates.each do |(workflow, id), script|
  variables = case id
              when "frontend_test" then %w[SHARD_RESULT INTEGRATION_RESULT]
              when "result" then ["TEST_RESULT"]
              else []
              end
  combinations = variables.reduce([{}]) { |rows, variable| rows.flat_map { |row| states.map { |state| row.merge(variable => state) } } }
  states.product(%w[true false invalid] + [""]).each do |selection_result, selected|
    combinations.each do |results|
      expected = selection_result == "success" && %w[true false].include?(selected)
      expected &&= case id
                   when "frontend_test_shard" then true
                   when "frontend_test"
                     results["SHARD_RESULT"] == "success" &&
                       results["INTEGRATION_RESULT"] == (selected == "true" ? "success" : "skipped")
                   when "result"
                     results["TEST_RESULT"] == (selected == "true" ? "success" : "skipped")
                   end
      env = results.merge("SELECTION_RESULT" => selection_result, "SELECTED" => selected)
      stdout, stderr, status = Open3.capture3(env.merge("BASH_ENV" => nil), "bash", "--noprofile", "--norc", "-e", "-c", script, chdir: root)
      check(status.success? == expected, "#{workflow}/#{id} #{env.inspect}: expected #{expected ? 'pass' : 'failure'}, exit #{status.exitstatus}\n#{stdout}#{stderr}")
      checks += 1
    end
  end
end
puts "CI workflow guards and wiring passed (#{checks} shell cases)."
