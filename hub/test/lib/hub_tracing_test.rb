require "test_helper"
require "open3"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/sdk/trace/export/in_memory_span_exporter"
require_relative "../../lib/hub_tracing/exporter"

class HubTracingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "default disabled and dummy builds do not load the tracing SDK" do
    [
      {},
      { "OTEL_TRACES_EXPORTER" => "none" },
      { "OTEL_TRACES_EXPORTER" => "otlp", "OTEL_SDK_DISABLED" => "true" },
      { "OTEL_TRACES_EXPORTER" => "otlp", "SECRET_KEY_BASE_DUMMY" => "1" }
    ].each do |configuration|
      output, error, status = run_startup(configuration, <<~RUBY)
        HubTracing.start!
        abort "SDK initialized while disabled" if defined?(OpenTelemetry::SDK)
        puts "disabled"
      RUBY

      assert status.success?, error
      assert_equal "disabled", output.strip
    end
  end

  test "invalid enabled configuration fails without printing endpoint credentials" do
    [
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => nil },
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://user:credential-canary@collector.example" },
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://collector.example?token=credential-canary" },
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://collector.example/#credential-canary" },
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => "https://[credential-canary" },
      { "OTEL_EXPORTER_OTLP_ENDPOINT" => "file:///credential-canary" },
      { "OTEL_EXPORTER_OTLP_PROTOCOL" => "grpc" },
      { "OTEL_TRACES_EXPORTER" => "console,otlp" }
    ].each do |invalid|
      configuration = {
        "OTEL_TRACES_EXPORTER" => "otlp",
        "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector.example"
      }.merge(invalid)
      output, error, status = run_startup(configuration, <<~RUBY)
        begin
          HubTracing.start!
        rescue ArgumentError => error
          puts error.message
          exit 42
        end
      RUBY

      assert_equal 42, status.exitstatus, "#{configuration.keys}: #{output} #{error}"
      refute_includes output + error, "credential-canary"
    end
  end

  test "serialized OTLP removes sensitive span data while preserving operational context" do
    memory = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(memory))
    tracer = provider.tracer("hub-tracing-test")
    sensitive = "private-value-canary"
    attributes = {
      "http.request.method" => "POST",
      "http.response.status_code" => 500,
      "http.route" => "/builds/:id",
      "db.system" => "sqlite",
      "db.operation" => "SELECT",
      "messaging.system" => "active_job",
      "messaging.operation" => "process",
      "code.namespace" => "TracingProbeJob",
      "http.request.header.authorization" => "Bearer #{sensitive}",
      "http.request.body" => sensitive,
      "url.full" => "https://user:#{sensitive}@example.com/#{sensitive}?token=#{sensitive}",
      "db.statement" => "SELECT '#{sensitive}'",
      "db.query.parameter.0" => sensitive,
      "job.arguments" => sensitive
    }
    link = OpenTelemetry::Trace::Link.new \
      OpenTelemetry::Trace::SpanContext.new,
      { "secret" => sensitive }
    span = tracer.start_span("POST /#{sensitive}", kind: :server, attributes:, links: [ link ])
    span.add_event(sensitive, attributes: { "exception.message" => sensitive })
    span.status = OpenTelemetry::Trace::Status.error(sensitive)
    span.finish
    client = tracer.start_span \
      "GET https://example.com/#{sensitive}",
      kind: :client,
      attributes: attributes.merge("http.request.method" => "GET")
    client.finish
    originals = memory.finished_spans
    requests = []
    intake = stub_request(:post, "http://collector.example/v1/traces").with do |request|
      requests << request
      true
    end.to_return(status: 200, body: "")
    exporter = HubTracing::Exporter.new \
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: "http://collector.example/v1/traces")

    assert_equal OpenTelemetry::SDK::Trace::Export::SUCCESS, exporter.export(originals, timeout: 1)

    assert_requested intake, times: 1
    assert_equal "application/x-protobuf", requests.first.headers["Content-Type"]
    payload = requests.first.body
    refute_includes payload, sensitive
    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(payload)
    exported = decoded.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    assert_equal [ "POST /builds/:id", "GET /builds/:id" ], exported.map(&:name)
    exported.zip(originals).each do |actual, original|
      assert_equal original.trace_id, actual.trace_id
      assert_equal original.span_id, actual.span_id
      assert_equal original.start_timestamp, actual.start_time_unix_nano
      assert_equal original.end_timestamp, actual.end_time_unix_nano
      assert_empty actual.events
      actual.links.each { |exported_link| assert_empty exported_link.attributes }
      metadata = actual.attributes.to_h { |attribute| [ attribute.key, attribute.value ] }
      assert_equal "SELECT", metadata.fetch("db.operation").string_value
      assert_equal "TracingProbeJob", metadata.fetch("code.namespace").string_value
      assert_equal 500, metadata.fetch("http.response.status_code").int_value
    end
    assert_equal :STATUS_CODE_ERROR, exported.first.status.code
    assert_empty exported.first.status.message
    assert_equal "POST /#{sensitive}", originals.first.name
    assert_equal sensitive, originals.first.events.first.name
    assert_equal sensitive, originals.first.status.description
  ensure
    exporter&.shutdown(timeout: 1)
    provider&.shutdown(timeout: 1)
  end

  private

  def run_startup(configuration, script)
    environment = ENV.keys.grep(/\AOTEL_/).to_h { |key| [ key, nil ] }
      .merge("SECRET_KEY_BASE_DUMMY" => nil)
      .merge(configuration)
    Open3.capture3 \
      environment,
      RbConfig.ruby,
      "-rbundler/setup",
      "-Ilib",
      "-rhub_tracing",
      "-e",
      script,
      chdir: Rails.root
  end
end
