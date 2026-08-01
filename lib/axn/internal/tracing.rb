# frozen_string_literal: true

require "securerandom"
require "axn/internal/identity"

# The capability probe rescues Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR, so this component needs
# the shared allowlist whether or not the umbrella entrypoint loaded it.
require "axn/extensions"

# autodetected_tracer names the instrumentation scope with Axn::VERSION, so this component cannot
# rely on the umbrella entrypoint having loaded the version first.
require "axn/version"

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
          cached = @tracer_entry
          return cached.last if cached && cached.first == current_provider

          # ONE immutable entry, assigned in a single reference store. Two ivars cannot express this
          # safely: a failed acquisition could leave them mismatched (a pair the check above reads as a
          # hit, pinning spans to the previous provider), and two threads racing on a provider swap
          # could interleave their writes into a pair belonging to neither. A reader sees the whole old
          # entry or the whole new one, so at worst it re-derives.
          tracer = current_provider.tracer("axn", Axn::VERSION)
          @tracer_entry = [current_provider, tracer].freeze
          tracer
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
        # Both checks below go through Internal::Identity rather than dispatching `nil?`/`equal?` to
        # the tracer: a proxy that overrides or forwards either would run on every call after the
        # first, outside the probe's rescue, and take down an action over an optional lookup.
        def supports_record_exception_option?(tracer)
          return false if Identity.nil_value?(tracer)

          cached = @probe_entry
          return cached.last if cached && Identity.same?(cached.first, tracer)

          supported = begin
            tracer.method(:in_span).parameters.any? { |type, name| name == :record_exception && %i[key keyreq].include?(type) }
          rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
            # Every class axn permits itself to absorb, not just StandardError: a proxy raising
            # SystemStackError from an overridden #method would otherwise escape an optional signature
            # lookup and abort the call. The answer for any failed probe is the same — assume the
            # option is unsupported and omit it.
            false
          end

          # One immutable entry, for the same reasons as the tracer memo above: a probe that unwinds
          # non-locally must not leave a tracer keyed to the PREVIOUS tracer's answer, and two threads
          # probing different tracers must not interleave into a pair belonging to neither — which
          # would hand one tracer the other's answer and send `record_exception:` to something with no
          # slot for it.
          @probe_entry = [tracer, supported].freeze
          supported
        end

        # Drops the auto-detection and capability memos, for specs that swap the OpenTelemetry
        # constant or the tracer out from under them.
        def reset!
          %i[@tracer_entry @probe_entry].each do |ivar|
            remove_instance_variable(ivar) if instance_variable_defined?(ivar)
          end
        end
      end
    end
  end
end
