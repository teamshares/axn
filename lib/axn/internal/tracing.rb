# frozen_string_literal: true

require "securerandom"

# autodetected_tracer names the instrumentation scope with Axn::VERSION, so this component cannot
# rely on the umbrella entrypoint having loaded the version first.
require "axn/version"

module Axn
  module Internal
    module Tracing
      # Identity comparison that cannot be intercepted by the object being compared.
      IDENTITY = BasicObject.instance_method(:equal?)
      private_constant :IDENTITY

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
        # Only a parameter actually DECLARED AS A KEYWORD (:key/:keyreq) counts — sharing the name
        # `record_exception` is not enough on its own. Two parameter shapes read as unsupported
        # despite matching the name:
        #   - `**opts` (:keyrest): axn omits the option, so an OTel >= 1.7 tracer underneath records
        #     the exception on top of axn's own `span.record_exception` — a duplicate event, not a
        #     crash.
        #   - a same-named POSITIONAL parameter (`def in_span(name, record_exception)`, :req):
        #     without this check, `tracer.in_span(name, **kwargs)` would fold the whole kwargs hash
        #     onto that one positional slot instead of binding the boolean axn intends.
        # Both are the safe direction to be wrong in: over-detecting instead sends the option to a
        # tracer whose #in_span has no slot for it at all, and `in_span` is called outside
        # `best_effort`, so the resulting ArgumentError would take down the call.
        #
        # Single-slot identity memo: there is one tracer per process, so a map would model tracers
        # that never exist, and the slot holds no reference Axn.config isn't already holding.
        #
        # Both checks below compare identity through BasicObject's own `equal?` rather than calling
        # the tracer's. A configured tracer promises `#in_span` and nothing else, so a proxy that
        # overrides or forwards `equal?`/`nil?` must not be dispatched to here — it would run on every
        # call after the first, outside the probe's rescue, and take down an action over an optional
        # observability lookup. BasicObject (not Object) owns the binding so it also holds for a
        # BasicObject-based proxy, and identity-against-nil is the undispatched form of `nil?`.
        def supports_record_exception_option?(tracer)
          return false if IDENTITY.bind_call(tracer, nil)
          return @supports_record_exception if defined?(@supports_record_exception) && IDENTITY.bind_call(@probed_tracer, tracer)

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
