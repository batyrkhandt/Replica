require "uri"

module HubTracing
  def self.start!
    return if ENV["SECRET_KEY_BASE_DUMMY"] || ENV["OTEL_SDK_DISABLED"]&.casecmp?("true")

    exporter = ENV.fetch("OTEL_TRACES_EXPORTER", "none")
    unless %w[none otlp].include?(exporter)
      raise ArgumentError, "OTEL_TRACES_EXPORTER must be none or otlp"
    end
    return if exporter == "none"

    protocol = ENV["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] ||
      ENV.fetch("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
    unless protocol == "http/protobuf"
      raise ArgumentError, "Hub tracing supports only the http/protobuf OTLP protocol"
    end
    endpoint = ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
    begin
      uri = URI.parse(endpoint.to_s)
    rescue URI::InvalidURIError
      raise ArgumentError, "OTLP endpoint must be an absolute HTTP(S) URL"
    end
    unless %w[http https].include?(uri.scheme) && uri.host &&
        !uri.userinfo && !uri.query && !uri.fragment
      raise ArgumentError, "OTLP endpoint must be an absolute HTTP(S) URL without credentials, query, or fragment"
    end

    require "opentelemetry/sdk"
    require "opentelemetry/exporter/otlp"
    require "opentelemetry/instrumentation/action_pack"
    require "opentelemetry/instrumentation/active_job"
    require "opentelemetry/instrumentation/net/http"
    require_relative "hub_tracing/exporter"

    processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      Exporter.new(OpenTelemetry::Exporter::OTLP::Exporter.new)
    )
    OpenTelemetry::SDK.configure do |config|
      config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "replica-hub")
      config.propagators = [ OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator ]
      config.add_span_processor(processor)
      config.use "OpenTelemetry::Instrumentation::Rack", untraced_endpoints: [ "/up" ]
      config.use "OpenTelemetry::Instrumentation::ActionPack", span_naming: :class
      config.use "OpenTelemetry::Instrumentation::ActiveJob",
        propagation_style: :child, span_naming: :job_class
      config.use "OpenTelemetry::Instrumentation::Net::HTTP"
    end

    # ORM instrumentation does not cover Hub's direct SQLite calls.
    tracer = OpenTelemetry.tracer_provider.tracer("replica-hub")
    ActiveSupport::Notifications.subscribe("sql.active_record") do |_, started, finished, _, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      span = tracer.start_span \
        "database query",
        kind: :client,
        start_timestamp: started,
        attributes: { "db.system.name" => "sqlite" }
      span.status = OpenTelemetry::Trace::Status.error if payload[:exception]
      span.finish(end_timestamp: finished)
    end
    at_exit { OpenTelemetry.tracer_provider.shutdown(timeout: 5) }
  end
end
