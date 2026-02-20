# frozen_string_literal: true

require "securerandom"

module Axn
  module Internal
    module Tracing
      class << self
        # Cache the tracer instance to avoid repeated lookups
        # The tracer provider may cache internally, but we avoid the method call overhead
        # We check defined?(OpenTelemetry) each time to handle cases where it's loaded lazily
        def tracer
          return nil unless defined?(OpenTelemetry)

          # Re-fetch if the tracer provider has changed (e.g., in tests with mocks)
          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn", Axn::VERSION)
        end

        # Check if the OpenTelemetry tracer supports the record_exception option for in_span.
        # This was added in opentelemetry-api 1.7.0 (2025-09-17).
        # We cache the result since method signature doesn't change at runtime.
        def supports_record_exception_option?
          return @supports_record_exception if defined?(@supports_record_exception)
          return @supports_record_exception = false unless defined?(OpenTelemetry)

          @supports_record_exception = begin
            OpenTelemetry::Trace::Tracer.instance_method(:in_span).parameters.any? { |_, name| name == :record_exception }
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
