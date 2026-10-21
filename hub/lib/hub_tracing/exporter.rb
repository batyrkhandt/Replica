require "timeout"

module HubTracing
  class Exporter
    # Keep this list aligned with the bundled instrumentation and Hub's diagnostic collectors.
    ATTRIBUTES = %w[
      http.request.method http.response.status_code http.method http.status_code http.route
      url.scheme http.scheme server.address server.port net.peer.name net.peer.port
      db.system.name db.query.text
      messaging.system messaging.destination messaging.message.id messaging.active_job.adapter.name
      messaging.active_job.message.provider_job_id messaging.active_job.message.priority
      code.namespace code.function replica.job.arguments
    ].freeze
    EXCEPTION_ATTRIBUTES = %w[exception.type exception.message exception.stacktrace].freeze

    def initialize(exporter)
      @exporter = exporter
    end

    def export(spans, timeout: nil)
      raise Timeout::Error if timeout && timeout <= 0

      # The bundled OTLP exporter's retry sleeps can outlast its request timeout.
      Timeout.timeout(timeout) do
        @exporter.export(spans.map { |span| sanitized(span) }, timeout:)
      end
    rescue Timeout::Error
      OpenTelemetry.handle_error(message: "OTLP export exceeded its deadline; trace batch dropped")
      OpenTelemetry::SDK::Trace::Export::TIMEOUT
    end

    def shutdown(timeout: nil)
      @exporter.shutdown(timeout:)
    end

    def force_flush(timeout: nil)
      @exporter.force_flush(timeout:)
    end

    private

    def sanitized(span)
      result = span.dup
      result.attributes = (span.attributes || {}).slice(*ATTRIBUTES)
      result.events = (span.events || []).filter_map do |event|
        next unless event.name == "exception"

        OpenTelemetry::SDK::Trace::Event.new \
          event.name,
          (event.attributes || {}).slice(*EXCEPTION_ATTRIBUTES),
          event.timestamp
      end
      result.links = []
      result.status = case span.status.code
      when OpenTelemetry::Trace::Status::ERROR then OpenTelemetry::Trace::Status.error
      when OpenTelemetry::Trace::Status::OK then OpenTelemetry::Trace::Status.ok
      else OpenTelemetry::Trace::Status.unset
      end
      method = result.attributes["http.request.method"] || result.attributes["http.method"]
      if span.kind == :server || method
        result.name = [ method || "HTTP", result.attributes["http.route"] ].compact.join(" ")
      end
      result
    end
  end
end
