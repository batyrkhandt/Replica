require "test_helper"
require "json"
require_relative "../../lib/hub_tracing/data_filter"

class HubTracingDataFilterTest < ActiveSupport::TestCase
  test "default argument filtering recursively removes structured identity and credential values without mutation" do
    identities = %w[email name username user_name first_name last_name display_name given_name family_name login]
    identity_values = identities.to_h { |key| [ key, "#{key}-identity-canary" ] }
    arguments = [
      {
        "nested" => [ identity_values ],
        "password" => "password-canary",
        "access_token" => "token-canary",
        "operation" => "publish"
      },
      "positional-diagnostic-canary"
    ]
    original = Marshal.load(Marshal.dump(arguments))

    result = JSON.parse(HubTracing::DataFilter.new.job_arguments(arguments))

    assert_equal original, arguments
    identities.each { |key| assert_equal "[FILTERED]", result.first.fetch("nested").first.fetch(key) }
    assert_equal "[FILTERED]", result.first.fetch("password")
    assert_equal "[FILTERED]", result.first.fetch("access_token")
    assert_equal "publish", result.first.fetch("operation")
    assert_equal "positional-diagnostic-canary", result.last
  end

  test "sensitive opt in retains identities while preserving additional Rails literal regex and proc filters" do
    original_filters = Rails.application.config.filter_parameters
    Rails.application.config.filter_parameters = [
      :email, "email", :password, :token, :customer_secret, /private_email/,
      ->(key, value) { value.replace("[APP FILTERED]") if key == "internal_note" }
    ]
    filter = HubTracing::DataFilter.new(include_sensitive_data: true)
    arguments = [
      {
        "email" => "person@example.test",
        "name" => "Example Person",
        "login" => "example-person",
        "password" => "password-canary",
        "token" => "token-canary",
        "customer_secret" => "app-secret-canary",
        "private_email" => "private@example.test",
        "internal_note" => "note-canary"
      }
    ]
    original = Marshal.load(Marshal.dump(arguments))

    result = JSON.parse(filter.job_arguments(arguments)).first

    assert_equal "person@example.test", result.fetch("email")
    assert_equal "Example Person", result.fetch("name")
    assert_equal "example-person", result.fetch("login")
    %w[password token customer_secret private_email].each do |key|
      assert_equal "[FILTERED]", result.fetch(key)
    end
    assert_equal "[APP FILTERED]", result.fetch("internal_note")
    assert_equal original, arguments
  ensure
    Rails.application.config.filter_parameters = original_filters
  end

  test "constructed filters retain identity policy and credentials after Rails replaces its source with precompiled rules" do
    original_filters = Rails.application.config.filter_parameters
    Rails.application.config.filter_parameters = [ :email, :password, :token, :customer_secret ]
    default_filter = HubTracing::DataFilter.new
    opted_in_filter = HubTracing::DataFilter.new(include_sensitive_data: true)
    source = Rails.application.config.filter_parameters
    source.replace(ActiveSupport::ParameterFilter.precompile_filters(source))
    arguments = [
      {
        "email" => "person@example.test",
        "name" => "Example Person",
        "password" => "password-canary",
        "token" => "token-canary",
        "customer_secret" => "app-secret-canary"
      }
    ]

    default = JSON.parse(default_filter.job_arguments(arguments)).first
    opted_in = JSON.parse(opted_in_filter.job_arguments(arguments)).first

    assert_equal "[FILTERED]", default.fetch("email")
    assert_equal "[FILTERED]", default.fetch("name")
    assert_equal "person@example.test", opted_in.fetch("email")
    assert_equal "Example Person", opted_in.fetch("name")
    [ default, opted_in ].each do |result|
      %w[password token customer_secret].each { |key| assert_equal "[FILTERED]", result.fetch(key) }
    end
  ensure
    Rails.application.config.filter_parameters = original_filters
  end

  test "sensitive opt in does not remove an application rule for another identity field" do
    original_filters = Rails.application.config.filter_parameters
    Rails.application.config.filter_parameters = [ :email, :name, /email/ ]
    arguments = [ { "email" => "person@example.test", "name" => "Example Person", "login" => "example-person" } ]

    result = JSON.parse(HubTracing::DataFilter.new(include_sensitive_data: true).job_arguments(arguments)).first

    assert_equal "[FILTERED]", result.fetch("email")
    assert_equal "[FILTERED]", result.fetch("name")
    assert_equal "example-person", result.fetch("login")
  ensure
    Rails.application.config.filter_parameters = original_filters
  end
end
