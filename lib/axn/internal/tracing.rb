# frozen_string_literal: true

require "securerandom"
require "axn/internal/identity"

# The capability probe rescues Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR, so this component needs
# the shared allowlist whether or not the umbrella entrypoint loaded it.
require "axn/extensions"

# autodetected_tracer names the instrumentation scope with Axn::VERSION, so this component cannot
# rely on the umbrella entrypoint having loaded the version first.
require "axn/version"

# `current_span` reaches Core::NestingTracking for "who is running" — a genuine runtime reference,
# deliberately NOT required here: `Core::NestingTracking` needs ActiveSupport (a third-party gem), and
# this file's own standalone-loadability is tested (component_loading_spec.rb) by loading it ALONE and
# calling `supports_record_exception_option?`, which never touches NestingTracking at all. Requiring it
# here would make merely LOADING this file — regardless of which method gets called — pull in
# ActiveSupport eagerly, which broke that pre-existing guarantee when tried (PRO-3278 review). Callers
# that need `current_span` to actually WORK get the require from `axn/extensions/tracing.rb`, the public
# facade that defines the only supported way to reach it.

module Axn
  module Internal
    module Tracing
      # The ivar `Core::Executor#with_current_span` publishes the `axn.call` span under, for the
      # duration of the action's own execution — not `private_constant`, because the executor writes
      # through this same constant rather than each side naming its own copy of the ivar.
      SPAN_IVAR = :@__axn_call_span

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
          # Identity, not `==`: the provider is an object the host app supplies, and validating a cache
          # must not run its code. A provider whose `==` answers true for a DIFFERENT provider would
          # pin spans to the replaced one forever, and one whose `==` raises a class axn never swallows
          # would abort the call from inside an optional lookup — `autodetected_tracer` resolves
          # outside the probe's rescue. Same seam and same reason as the capability memo below.
          return cached.last if cached && Identity.same?(cached.first, current_provider)

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

        # The span axn's tracer yielded for the innermost currently-executing action, or nil — read
        # directly off the action instance rather than through OpenTelemetry's own ambient
        # `Trace.current_span`, which resolves through `OpenTelemetry::Context.current` and so through
        # whatever else in the process has touched that process-wide, mutable state between when axn
        # opened its span and now (verified against the Datadog OTel bridge in production; the general
        # failure isn't specific to it — see PRO-3278). The two answers can disagree, and this one is
        # the span the CURRENT action actually ran inside, never an ancestor's and never a sibling's.
        #
        # `isolation_unsafe?` gated first: under the known fiber-scheduler/isolation_level mismatch,
        # `Core::NestingTracking._current_axn_stack` is shared, unlocked, across concurrent fibers on
        # one thread, so `.last` can already answer with a different fiber's action. Handing back that
        # action's span would be worse than today's silent ambient-lookup failure — a consumer would
        # write real attributes onto a trace it does not own. Refusing to answer degrades to exactly
        # that pre-existing failure mode (nothing written) instead of a new, worse one.
        #
        # A SECOND, independent check below the first: `isolation_unsafe?` only sees a Fiber SCHEDULER
        # mismatch, but the same shared-stack hazard is reachable with no scheduler at all — Fibers
        # created and `.resume`d by hand, with no scheduler ever installed, still share `Thread.current`,
        # and so still share `_current_axn_stack` under `isolation_level == :thread` (PRO-3278 review,
        # reproduced directly: fiber A pushes and yields mid-body, fiber B pushes and yields, A resumes
        # and `current_axn` returns B). That is a `NestingTracking` stack-correctness gap this method
        # cannot repair — `_current_axn_stack` genuinely may hold the wrong action on top — but it does
        # not have to trust the action `current_axn` hands back: `with_current_span` tags the span with
        # the thread+fiber that published it, and this refuses to return one tagged for a DIFFERENT
        # fiber than the one actually asking. B's span was tagged with B's fiber identity, not A's, so
        # A reading it here — even though `current_axn` wrongly resolved to B — gets nil instead of a
        # span it would silently misattribute.
        #
        # nil is the honest answer whenever `Core::NestingTracking.current_axn` is nil (no action
        # running at all), that action never had a span published for it (no tracer configured, the
        # tracer never yielded, the tracer yielded `nil`, or the untraced fallback ran the action), or
        # the published span belongs to a different thread/fiber than the one calling now.
        def current_span
          return nil if Axn::Core::NestingTracking.isolation_unsafe?

          action = Axn::Core::NestingTracking.current_axn
          return nil unless action

          tagged = Internal::NativeMethods.ivar_get(action, SPAN_IVAR)
          return nil unless tagged

          span, thread, fiber = tagged
          return nil unless Identity.same?(thread, Thread.current) && Identity.same?(fiber, Fiber.current)

          span
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
