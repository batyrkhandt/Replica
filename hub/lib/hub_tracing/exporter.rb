module HubTracing
  class Exporter
    # Export operational metadata, not request content or SDK-generated exception messages.
    ATTRIBUTES = %w[
      http.request.method http.response.status_code http.method http.status_code http.route
      url.scheme http.scheme server.address server.port net.peer.name net.peer.port
      db.system db.system.name db.operation db.operation.name
      messaging.system messaging.operation messaging.operation.name messaging.operation.type
      messaging.destination.name messaging.destination_kind code.namespace code.function
    ].freeze

    def initialize(exporter)
      @exporter = exporter
    end

    def export(spans, timeout: nil)
      @exporter.export(spans.map { |span| sanitized(span) }, timeout:)
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
      result.events = []
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
