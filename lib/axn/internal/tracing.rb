# frozen_string_literal: true

require "securerandom"

module Axn
  module Internal
    module Tracing
      class << self
        # The OpenTelemetry tracer, when OpenTelemetry is loaded. Mechanism only: whether axn traces
        # at all, and with which tracer, is Axn.config.tracer's decision. The presence check runs on
        # every call because OpenTelemetry can be loaded lazily, and the provider is re-consulted
        # because it can be replaced (a host app configuring the SDK after boot, or a test swapping
        # in a mock).
        def autodetected_tracer
          return nil unless defined?(OpenTelemetry)

          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn", Axn::VERSION)
        end

        # Axn.config.tracer's dynamic default calls through here, so this stays a one-line delegate
        # rather than duplicated logic.
        def tracer = autodetected_tracer

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

        # Drops the auto-detection and capability memos, for specs that swap the OpenTelemetry
        # constant or the tracer out from under them.
        def reset!
          %i[@tracer @tracer_provider @supports_record_exception @probed_tracer].each do |ivar|
            remove_instance_variable(ivar) if instance_variable_defined?(ivar)
          end
        end
      end
    end
  end
end
