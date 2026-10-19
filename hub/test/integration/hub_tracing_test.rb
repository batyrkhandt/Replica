require "test_helper"
require "open3"
require "base64"
require "opentelemetry/exporter/otlp"

class HubTracingIntegrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "normal boot traces requests serialized child jobs database and outbound HTTP without private content" do
    result = run_traced_request

    assert_equal 200, result.fetch("status")
    assert_equal "completed", result.fetch("body")
    assert result.fetch("job_performed")
    assert_equal 200, result.fetch("health_status")
    refute result.fetch("baggage_propagated"), "incoming baggage reached the outbound service"
    payloads = result.fetch("payloads").map { |payload| Base64.strict_decode64(payload) }
    assert_not_empty payloads, result.fetch("diagnostics")
    payloads.each { |payload| refute_includes payload, "private-value-canary" }
    spans = payloads.flat_map do |payload|
      request = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(payload)
      request.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    end
    server = spans.find { |span| span.kind == :SPAN_KIND_SERVER }
    assert server, "Rails boot did not produce a server span"
    assert_equal "POST /tracing-probe", server.name
    assert_equal "1234567890abcdef1234567890abcdef", server.trace_id.unpack1("H*")
    assert_equal 1, spans.count { |span| span.kind == :SPAN_KIND_SERVER }, "health check was traced"
    jobs = spans.select { |span| span.name.include?("TracingProbeJob") }
    assert_operator jobs.size, :>=, 2, "enqueue and serialized execution must both be traced"
    assert jobs.all? { |span| span.trace_id == server.trace_id }, "job execution lost its request trace"
    jobs.each do |job|
      assert spans.any? { |parent| parent.span_id == job.parent_span_id }, "job has no exported parent"
    end
    metadata = spans.flat_map(&:attributes)
    assert metadata.any? { |attribute| attribute.key.start_with?("db.system") }
    assert spans.any? { |span| span.kind == :SPAN_KIND_CLIENT }, "outbound HTTP was not traced"
    spans.each do |span|
      assert_empty span.events
      assert_empty span.status.message if span.has_status?
    end
  end

  test "an unavailable collector does not interrupt a request or serialized job and flush is bounded" do
    result = run_traced_request(collector_failure: true)

    assert_equal 200, result.fetch("status")
    assert_equal "completed", result.fetch("body")
    assert result.fetch("job_performed")
    assert_operator result.fetch("export_attempts"), :>, 0
    assert_operator result.fetch("request_seconds"), :<, 5
    assert_operator result.fetch("flush_seconds"), :<, 5
  end

  test "a forked worker exports new job spans without replaying its parents pending request" do
    result = run_traced_request(fork_worker: true)

    assert_equal 0, result.fetch("worker_exitstatus")
    assert result.fetch("worker_performed")
    spans = result.fetch("worker_payloads").flat_map do |payload|
      request = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode \
        Base64.strict_decode64(payload)
      request.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    end
    assert spans.any? { |span| span.name.include?("TracingProbeJob") }, "forked worker did not export"
    refute spans.any? { |span| span.kind == :SPAN_KIND_SERVER }, "child re-exported its parent's request"
    spans.each { |span| assert_empty span.events }
  end

  private

  def run_traced_request(collector_failure: false, fork_worker: false)
    environment = ENV.keys.grep(/\AOTEL_/).to_h { |key| [ key, nil ] }
    environment.merge! \
      "SECRET_KEY_BASE_DUMMY" => nil,
      "RAILS_ENV" => "test",
      "OTEL_TRACES_EXPORTER" => "otlp",
      "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" => "http://collector.example/v1/traces",
      "OTEL_EXPORTER_OTLP_TIMEOUT" => "1",
      "OTEL_BSP_SCHEDULE_DELAY" => "60000",
      "OTEL_BSP_EXPORT_TIMEOUT" => "1000"
    script = <<~RUBY
      require "webmock"
      require "json"
      require "base64"
      WebMock.enable!
      WebMock.disable_net_connect!
      require_relative "config/environment"
      payloads = []
      export_attempts = 0
      baggage_propagated = false
      intake = WebMock.stub_request(:post, "http://collector.example/v1/traces")
      if #{collector_failure}
        intake.to_return do
          export_attempts += 1
          raise Errno::ECONNREFUSED
        end
      else
        intake.to_return do |request|
          export_attempts += 1
          payloads << Base64.strict_encode64(request.body)
          { status: 200, body: "" }
        end
      end
      WebMock.stub_request(:get, "http://upstream.example/private-value-canary?token=private-value-canary")
        .to_return do |request|
          baggage_propagated ||= request.headers.key?("Baggage")
          { status: 200, body: "private-value-canary" }
        end
      class TracingProbeJob < ActiveJob::Base
        def perform(secret)
          raise "job argument changed" unless secret == "private-value-canary"
          self.class.performed = true
        end
        class_attribute :performed, default: false
      end
      TracingProbeJob.queue_adapter = :test
      class TracingProbeController < ActionController::Base
        def create
          ActiveRecord::Base.connection.select_value("SELECT 'private-value-canary'")
          Net::HTTP.get(URI("http://upstream.example/private-value-canary?token=private-value-canary"))
          TracingProbeJob.perform_later("private-value-canary")
          queued = TracingProbeJob.queue_adapter.enqueued_jobs.shift.select { |key, _| key.is_a?(String) }
          serialized = JSON.parse(JSON.generate(queued))
          ActiveJob::Base.execute(serialized)
          render plain: "completed"
        end
      end
      Rails.application.routes.draw do
        post "/tracing-probe", to: "tracing_probe#create"
        get "/up", to: "rails/health#show"
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      request = Rack::MockRequest.env_for \
        "/tracing-probe?token=private-value-canary",
        method: "POST",
        "HTTP_AUTHORIZATION" => "Bearer private-value-canary",
        "HTTP_BAGGAGE" => "secret=private-value-canary",
        "HTTP_TRACEPARENT" => "00-1234567890abcdef1234567890abcdef-1234567890abcdef-01",
        input: "private-value-canary",
        "CONTENT_TYPE" => "text/plain"
      status, headers, body = Rails.application.call(request)
      response_body = body.each.to_a.join
      body.close if body.respond_to?(:close)
      request_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      health_status, _, health_body = Rails.application.call(Rack::MockRequest.env_for("/up"))
      health_body.each { |_part| }
      health_body.close if health_body.respond_to?(:close)
      worker = {}
      if #{fork_worker}
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          payloads.clear
          TracingProbeJob.performed = false
          TracingProbeJob.perform_now("private-value-canary")
          OpenTelemetry.tracer_provider.force_flush(timeout: 1)
          OpenTelemetry.tracer_provider.shutdown(timeout: 1)
          writer.write(JSON.generate(payloads: payloads, performed: TracingProbeJob.performed))
          writer.close
          exit! 0
        end
        writer.close
        worker = JSON.parse(reader.read)
        reader.close
        _, worker_status = Process.wait2(pid)
        worker["exitstatus"] = worker_status.exitstatus
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      OpenTelemetry.tracer_provider.force_flush(timeout: 1)
      flush_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      result = JSON.generate \
        status: status,
        body: response_body,
        job_performed: TracingProbeJob.performed,
        health_status: health_status,
        baggage_propagated: baggage_propagated,
        payloads: payloads,
        export_attempts: export_attempts,
        request_seconds: request_seconds,
        flush_seconds: flush_seconds,
        worker_payloads: worker["payloads"],
        worker_performed: worker["performed"],
        worker_exitstatus: worker["exitstatus"]
      puts "HUB_TRACING_RESULT=" + result
    RUBY
    output, error, status = Open3.capture3 \
      environment,
      RbConfig.ruby,
      "-rbundler/setup",
      "-e",
      script,
      chdir: Rails.root
    assert status.success?, "Tracing subprocess failed:\n#{output}\n#{error}"
    result = output.lines.find { |line| line.start_with?("HUB_TRACING_RESULT=") }
    assert result, "Tracing subprocess returned no result:\n#{output}\n#{error}"
    JSON.parse(result.delete_prefix("HUB_TRACING_RESULT="))
      .merge("diagnostics" => "#{output}\n#{error}")
  end
end
