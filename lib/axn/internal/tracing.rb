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

        # Whether THIS tracer's #in_span accepts the `record_exception:` option (added in
        # opentelemetry-api 1.7.0). Asks the object actually being called rather than
        # OpenTelemetry::Trace::Tracer, whose signature says nothing about an injected tracer and can
        # be wrong in both directions.
        #
        # Only an explicitly-named keyword counts. A tracer declaring `**opts` reports :keyrest and is
        # read as unsupported, so axn omits the option and an OTel >= 1.7 tracer underneath records the
        # exception on top of axn's own `span.record_exception` — a duplicate event. That is the safe
        # direction: over-detecting sends the option to a strict-arity tracer, and `in_span` is called
        # outside `best_effort`, so the resulting ArgumentError would take down the call.
        #
        # Single-slot identity memo: there is one tracer per process, so a map would model tracers
        # that never exist, and the slot holds no reference Axn.config isn't already holding.
        def supports_record_exception_option?(tracer)
          return false if tracer.nil?
          return @supports_record_exception if defined?(@supports_record_exception) && @probed_tracer.equal?(tracer)

          @probed_tracer = tracer
          @supports_record_exception = begin
            tracer.method(:in_span).parameters.any? { |type, name| name == :record_exception && %i[key keyreq].include?(type) }
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
