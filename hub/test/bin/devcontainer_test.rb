require "test_helper"
require "fileutils"
require "open3"
require "securerandom"

class DevcontainerTest < ActiveSupport::TestCase
  test "dev starts local mode and prepares the example by default" do
    calls = dev_calls(mode: nil)

    assert_equal 4, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails db:prepare\z/, calls[1])
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails runner LocalDevelopment.seed_example!\z/, calls[2])
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/dev\z/, calls[3])
  end

  test "zero starts GitHub-backed development without seeding" do
    calls = dev_calls(mode: "0")

    assert_equal 2, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=0 bin\/dev\z/, calls[1])
  end

  test "false starts GitHub-backed development without seeding" do
    calls = dev_calls(mode: "false")

    assert_equal 2, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=0 bin\/dev\z/, calls[1])
  end

  test "up without a proxy keeps the public npm startup path" do
    result = devcontainer("up", image_exists: false)

    assert result[:status].success?, result[:output]
    build = result[:calls].find { |call| call.first == "build" }
    assert build, "A missing CLI image must be built"
    assert_nil option_value(build, "--build-arg")
    assert_equal 1, cli_calls(result).length
    assert_equal "up", cli_calls(result).first.first
    assert_nil option_value(cli_calls(result).first, "--remote-env")
  end

  test "up configures the requested proxy for CLI installation and the container lifetime" do
    registry = "https://packages.example.test/npm/"
    result = devcontainer("up", "--use-npm-proxy", registry)

    assert result[:status].success?, result[:output]
    build = result[:calls].find { |call| call.first == "build" }
    assert build, "Selecting a proxy must not reuse an existing public-registry CLI image"
    assert_equal "NPM_CONFIG_REGISTRY=#{registry}", option_value(build, "--build-arg")
    startup, persistence = cli_calls(result)
    assert_equal "up", startup.first
    assert_equal "NPM_CONFIG_REGISTRY=#{registry}", option_value(startup, "--remote-env")
    assert_equal [ "npm", "config", "set", "registry", registry, "--location=user" ], exec_payload(persistence)
    assert_equal 2, cli_calls(result).length
    assert_equal "registry=https://host.example.test/npm/\n", result[:host_npm_config]
    assert_equal "min-release-age=10080\n", result[:project_npm_config]
    assert_empty result[:host_npm_calls]
    refute_match(/strict[-_]ssl[= ]false|NODE_TLS_REJECT_UNAUTHORIZED=0/i, result[:calls].flatten.join(" "))
  end

  test "dev with a proxy still prepares and starts local development after configuring npm" do
    registry = "https://packages.example.test/npm/"
    result = devcontainer("dev", "--use-npm-proxy", registry)

    assert result[:status].success?, result[:output]
    calls = cli_calls(result)
    assert_equal 5, calls.length
    assert_equal "NPM_CONFIG_REGISTRY=#{registry}", option_value(calls[0], "--remote-env")
    assert_includes exec_payload(calls[1]), registry
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails db:prepare\z/, calls[2].join(" "))
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails runner LocalDevelopment.seed_example!\z/, calls[3].join(" "))
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/dev\z/, calls[4].join(" "))
  end

  test "other startup commands accept the proxy without changing their payload" do
    registry = "http://packages.example.test:4873/npm/"
    commands = {
      "rebuild" => [],
      "storybook" => [ "npm", "run", "storybook" ],
      "shell" => [ "bash" ],
      "exec" => [ "printf", "%s", "two words", "--use-npm-proxy", "payload value" ]
    }

    commands.each do |command, payload|
      arguments = command == "exec" ? payload : []
      result = devcontainer(command, "--use-npm-proxy", registry, *arguments)

      assert result[:status].success?, "#{command}: #{result[:output]}"
      calls = cli_calls(result)
      assert_equal "NPM_CONFIG_REGISTRY=#{registry}", option_value(calls[0], "--remote-env"), command
      assert_equal [ "npm", "config", "set", "registry", registry, "--location=user" ], exec_payload(calls[1]), command
      if command == "rebuild"
        assert_includes calls[0], "--remove-existing-container"
        assert_equal 2, calls.length
      else
        assert_equal payload, exec_payload(calls[2]), command
        assert_equal 3, calls.length
      end
    end
  end

  test "exec preserves proxy-looking payload arguments and explicit container environment" do
    payload = [ "printf", "%s\n", "two words", "", "--use-npm-proxy", "not a registry", "single'quote" ]
    secret = "bootstrap secret with 'quotes'"
    result = devcontainer("exec", *payload, mode: "0", bootstrap_secret: secret)

    assert result[:status].success?, result[:output]
    calls = cli_calls(result)
    assert_equal 2, calls.length
    assert_nil option_value(calls.first, "--remote-env")
    arguments = exec_payload(calls.last)
    assert_equal "env", arguments.shift
    environment = arguments.shift(2)
    assert_includes environment, "REPLICA_LOCAL_MODE=0"
    assert_includes environment, "REPLICA_BOOTSTRAP_SECRET=#{secret}"
    assert_equal payload, arguments
    assert_nil result[:calls].find { |call| call.first == "build" }
  end

  test "failed startup does not save the proxy inside the container" do
    result = devcontainer("up", "--use-npm-proxy", "https://packages.example.test/npm/", up_success: false)

    refute result[:status].success?
    assert_equal [ "up" ], cli_calls(result).map(&:first)
  end

  test "missing and invalid proxy URLs fail before Docker is called" do
    invalid_arguments = [
      [],
      [ "" ],
      [ "not-a-url" ],
      [ "ftp://packages.example.test/npm/" ],
      [ "https://" ],
      [ "https:///npm/" ],
      [ "https://user:password@packages.example.test/npm/" ],
      [ "https://packages.example.test/npm with spaces/" ],
      [ "https://packages.example.test/npm/\n" ],
      [ "https://packages.example.test/npm/?token=value" ],
      [ "https://packages.example.test/npm/#fragment" ]
    ]

    invalid_arguments.each do |arguments|
      result = devcontainer("up", "--use-npm-proxy", *arguments)

      refute result[:status].success?, arguments.inspect
      assert_empty result[:calls], arguments.inspect
      assert_not_empty result[:output].strip, arguments.inspect
    end
  end

  test "unexpected command arguments fail before Docker is called" do
    [
      [ "up", "unexpected" ],
      [ "dev", "--unknown" ],
      [ "rebuild", "--use-npm-proxy", "https://packages.example.test/npm/", "unexpected" ],
      [ "storybook", "unexpected" ],
      [ "shell", "unexpected" ],
      [ "stop", "unexpected" ],
      [ "down", "unexpected" ],
      [ "exec" ],
      [ "exec", "--use-npm-proxy", "https://packages.example.test/npm/" ]
    ].each do |arguments|
      result = devcontainer(*arguments)

      refute result[:status].success?, arguments.inspect
      assert_empty result[:calls], arguments.inspect
    end
  end

  private

  def dev_calls(mode:)
    result = devcontainer("dev", mode: mode)
    assert result[:status].success?, result[:output]
    cli_calls(result).map { |call| call.join(" ") }
  end

  def cli_calls(result)
    result[:calls].filter_map do |call|
      next unless call.first == "run"

      command = call.index { |argument| %w[up exec].include?(argument) }
      call.drop(command)
    end
  end

  def exec_payload(call)
    assert call, "Expected a command inside the container"
    assert_equal "exec", call.first
    call.drop(call.index("--workspace-folder") + 2)
  end

  def option_value(arguments, option)
    index = arguments.index(option)
    return arguments[index + 1] if index

    arguments.find { |argument| argument.start_with?("#{option}=") }&.delete_prefix("#{option}=")
  end

  def devcontainer(*arguments, mode: nil, bootstrap_secret: nil, image_exists: true, up_success: true)
    directory = Rails.root.join("test", ".devcontainer-#{SecureRandom.hex(8)}")
    FileUtils.mkdir_p([ directory.join("bin"), directory.join("home") ])
    FileUtils.cp(Rails.root.join("bin/devcontainer"), directory.join("bin/devcontainer"))
    File.write(directory.join(".npmrc"), "min-release-age=10080\n")
    File.write(directory.join("home/.npmrc"), "registry=https://host.example.test/npm/\n")
    File.write(directory.join("bin/docker"), <<~'SH')
      #!/bin/sh
      printf '%s\0' "$#" "$@" >> "$DOCKER_CALLS"
      if [ "$1" = image ]; then exit "$DOCKER_IMAGE_STATUS"; fi
      if [ "$DOCKER_UP_STATUS" != 0 ]; then
        for argument do
          if [ "$argument" = up ]; then exit "$DOCKER_UP_STATUS"; fi
        done
      fi
    SH
    File.write(directory.join("bin/npm"), <<~'SH')
      #!/bin/sh
      printf '%s\n' "$*" >> "$HOST_NPM_CALLS"
      exit 1
    SH
    FileUtils.chmod(0o755, [ directory.join("bin/docker"), directory.join("bin/npm") ])
    environment = {
      "PATH" => "#{directory.join('bin')}:#{ENV.fetch('PATH')}",
      "DOCKER_CALLS" => directory.join("calls").to_s,
      "DOCKER_IMAGE_STATUS" => image_exists ? "0" : "1",
      "DOCKER_UP_STATUS" => up_success ? "0" : "1",
      "HOST_NPM_CALLS" => directory.join("host-npm-calls").to_s,
      "HOME" => directory.join("home").to_s,
      "NPM_CONFIG_USERCONFIG" => directory.join("home/.npmrc").to_s,
      "REPLICA_LOCAL_MODE" => mode,
      "REPLICA_BOOTSTRAP_SECRET" => bootstrap_secret
    }
    output, error, status = Open3.capture3 \
      environment,
      directory.join("bin/devcontainer").to_s,
      *arguments
    recorded = directory.join("calls").exist? ? directory.join("calls").binread.split("\0", -1) : []
    calls = []
    calls << recorded.shift(recorded.shift.to_i) while recorded.length > 1
    {
      calls: calls,
      output: "#{output}\n#{error}",
      status: status,
      host_npm_config: directory.join("home/.npmrc").read,
      project_npm_config: directory.join(".npmrc").read,
      host_npm_calls: directory.join("host-npm-calls").exist? ? directory.join("host-npm-calls").read : ""
    }
  ensure
    FileUtils.remove_entry(directory) if directory&.exist?
  end
end
