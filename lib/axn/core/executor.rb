# frozen_string_literal: true

require "axn/internal/rendering"

module Axn
  module Core
    # Executor encapsulates the full execution pipeline for an action.
    # It owns all the wrapper logic that was previously spread across instance methods,
    # reducing the number of methods injected into user classes.
    #
    # The execution pipeline has two zones separated by the exception boundary:
    #
    # **Outside zone** (result settled, must not raise):
    # - nesting_tracking: manages the axn stack
    # - tracing: reads result.outcome, result.elapsed_time, result.exception
    # - logging: reads result.ok?, result.outcome, result.elapsed_time
    #
    # **Boundary:**
    # - exception_handling: catches exceptions, sets result state, dispatches callbacks
    #
    # **Inside zone** (can raise fail!/done!):
    # - timing: sets elapsed_time via ensure
    # - contract: validates inputs/outputs, applies defaults/preprocessing
    # - hooks: user before/after/around hooks
    # What happened to ONE attempt at running the action, so the observers wrapped around it cannot
    # misreport it. Tracing calls an app-supplied object that WRAPS the action (`in_span` takes the
    # work as a block), so the action's fate and the observer's are entangled by construction — this
    # is what keeps them separable:
    #
    #   started?    the exactly-once guarantee: the action began, so nothing may run it again
    #   error       the exception the wrapped stack raised, kept so an observer that swallows,
    #               replaces, or re-raises it cannot decide the call's outcome
    #   abandoned?  a `throw` unwound the stack BEFORE the result settled. Unlike an exception this
    #               cannot be re-thrown once an observer has caught it — the tag and value are gone —
    #               so it exists only to refuse to report a success. A throw that unwinds AFTER
    #               settlement is a side channel failing on its way out, not the action being
    #               abandoned, and leaves the settled result alone.
    #   settled?    whether the action's RESULT finalized, asked of the action rather than inferred
    #               from how this block ended. The two diverge exactly where it matters: a completion-
    #               side unwind leaves a settled result behind, and it is settlement — not a normal
    #               return — that decides both abandonment above and whether a span has an outcome
    #               worth describing.
    class ActionAttempt
      attr_reader :error

      # `settled` answers whether the action's result has FINALIZED — the same `finalized?` signal
      # `log_after` gates on, and true on every settling path (success, `fail!`, `done!`, a recorded
      # exception). Injected as a predicate rather than read from the action here so the attempt stays
      # a record of what happened to one call, with no opinion about how a result is shaped.
      def initialize(settled:)
        @settled = settled
        # The thread AND fiber the call arrived on — the two axes ActiveSupport::IsolatedExecutionState
        # scopes by, and axn's per-execution state (nesting stack, exception classification, carried
        # presentation) was established out here before tracing began. A body running elsewhere sees an
        # empty axn stack: wrong log prefixes, wrong nested-call classification, wrong breadcrumbs.
        #
        # The fiber matters for a second reason the thread does not: a block invoked in a fresh Fiber
        # can SUSPEND mid-action and hand control back, so `in_span` returns with the action started
        # and unfinished, and the caller is given a result still being written.
        @thread = Thread.current
        @fiber = Fiber.current
        @lock = Thread::Mutex.new
        @claimed = false
        @notification_claimed = false
        @started = false
        @completed = false
        @error = nil
        @abandoned = false
        @closed = false
      end

      # Ends the attempt's lifetime at the tracing boundary, so nothing may act on it afterward.
      # Context identity alone cannot express this: a tracer that CAPTURES the block it was handed,
      # cancels out before invoking it, and calls it later on the same thread and fiber presents an
      # originating context that is genuinely the caller's — just no longer a live one. The cancellation
      # path deliberately leaves both claims unused (the fallback must not run the action after the
      # caller has given up), so without this the deferred callback would find them available and turn
      # abandoned work into committed side effects.
      def close!
        @lock.synchronize { @closed = true }
      end

      # Whether the action BODY began. Deliberately not the same as having been claimed: an observer
      # can claim the attempt and then fail before reaching the action (a notification subscriber
      # raising from `start`), and the untraced fallback has to be able to tell those apart.
      # Raises unless called on the thread the attempt was created on. Checked BEFORE claiming, so a
      # tracer that hands the block to a worker cannot start the action there — the untraced fallback
      # then runs it on the right thread, with the execution state it belongs to, rather than the call
      # being lost.
      # True when the caller is on the thread and fiber the attempt was created on — so it is a context
      # that could legitimately have run the action, rather than one whose block was refused.
      # Through Internal::Identity like every other identity check on this path, rather than dispatching
      # `equal?` to a Thread or Fiber the app may have subclassed. Same reasoning as `swallowable?`: the
      # object's opinion of its own identity was never the question, and this answer decides whether a
      # context may claim the notification and run the action — so it has to come from the objects
      # themselves, not from a method one of them defines.
      def originating_context? = Internal::Identity.same?(Thread.current, @thread) && Internal::Identity.same?(Fiber.current, @fiber)

      def require_originating_context!
        return if originating_context?

        raise "axn.call tracing invoked the action on a different thread or fiber than the caller's: a " \
              "tracer must invoke the block it is given synchronously, on the calling thread and fiber."
      end

      def claimed? = @claimed
      def started? = @started

      def abandoned? = @abandoned

      # Takes the one permitted attempt, returning false if it is already taken. Checking and taking
      # are ONE operation: a tracer may invoke the block it was handed from more than one thread, and
      # a separate test could pass in several of them before any set the flag — which would run the
      # business action more than once.
      def claim
        @lock.synchronize do
          return false if @closed || @claimed

          @claimed = true
          true
        end
      end

      # The same one-winner rule for emitting `axn.call`, tracked separately from the action's claim
      # because the two are not the same event: a notification can be attempted and fail before the
      # action begins, and must not then be retried — a subscriber may already have committed a side
      # effect. Claiming rather than testing a flag matters for the same reason it does above: a tracer
      # yielding from two threads could otherwise emit the event twice.
      def claim_notification
        @lock.synchronize do
          return false if @closed || @notification_claimed

          @notification_claimed = true
          true
        end
      end

      # Records how a block completed WITHOUT claiming or starting anything — for work wrapped around
      # the action (the notification) whose abnormal exit must be visible for the same reasons.
      def observe
        completed = false
        raised = false
        begin
          value = yield
          completed = true
          value
        rescue Exception => e # rubocop:disable Lint/RescueException
          raised = true
          # An observer raising an ORDINARY error is an observer failure: logged and swallowed by the
          # guard, which then lets the fallback run the action. Deliberately not recorded, or a
          # subscriber's own bug would propagate as the action's outcome.
          #
          # A class axn never swallows is the opposite — a cancellation passing through, which a
          # tracer that absorbs everything would otherwise erase, leaving the fallback free to run the
          # action after its caller had already given up.
          # Ordinarily an observer raising an ordinary error is an observer FAILURE — logged, swallowed,
          # and the fallback still runs the action. Under dev-loud that policy inverts: best_effort
          # re-raises tracing failures on purpose, so a tracer that swallows must not be able to quietly
          # undo it. Recorded in that mode so the guard re-raises it.
          @error ||= e unless Axn::Extensions.swallowable?(e) && !Axn::Extensions.raises_in_dev?
          raise
        ensure
          # `@started` matters here and not in `execute`: an unwind through the notification AFTER the
          # action has run is a side channel failing on its way out, not the action being abandoned.
          # Marking it abandoned would let a subscriber throwing from `finish` replace a settled result
          # with a synthetic error.
          @abandoned = true unless completed || raised || @error || @started
        end
      end

      def execute
        @started = true
        begin
          value = yield
          @completed = true
          value
        # Every escaping class, not axn's swallow allowlist: this RECORDS and always re-raises, never
        # absorbs, so widening it does not widen what axn swallows. A tracer wrapping its yield in
        # `rescue Exception` can eat an `Interrupt` from the wrapped stack as easily as a
        # `StandardError`, and a cancellation turning into a reported success is the worst outcome
        # available here.
        rescue Exception => e # rubocop:disable Lint/RescueException
          @error = e
          raise
        ensure
          # `settled?` is what separates the two unwinds that reach here without an exception. A
          # `throw` from the action's own body abandoned the call and must never be reported as a
          # success. A `throw` from the completion side — `with_logging`'s `log_after`, `with_timing`'s
          # ensure, both of which run INSIDE this block but after `with_exception_handling` settled the
          # result — is a side channel failing on its way out of a call that already finished. Marking
          # that abandoned would let a logger take down a completed action, which is the same failure
          # `observe` refuses via `@started` one layer out.
          @abandoned = true unless @completed || @error || settled?
        end
      end

      # Deliberately swallows everything: this is consulted from an `ensure` while a `throw` is
      # unwinding, so a raise here would replace the in-flight unwind with an error from the very
      # bookkeeping meant to preserve it. An unanswerable predicate means "not known to have settled",
      # which is the conservative reading — it keeps the pre-existing abandonment behavior.
      def settled?
        @settled.call
      rescue Exception # rubocop:disable Lint/RescueException
        false
      end
    end

    class Executor # rubocop:disable Metrics/ClassLength
      def initialize(action)
        @action = action
        @action_class = action.class
        @context = action.instance_variable_get(:@__context)
      end

      def run
        Core::NestingTracking.tracking(@action) do
          with_tracing do
            with_logging do
              with_timing do
                with_exception_handling do
                  with_contract do
                    with_hooks do
                      @action.call
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Best-effort inbound preparation for OUT-OF-BAND facet resolution — the async exhaustion/discard
      # report path (Axn::Async::ExceptionReporting), where an action is reconstructed from job args and
      # never executed. Top-level and subfield coerce/preprocess/default now resolve lazily on the read
      # path (ContractForSubfields.resolve_value), so a facet reading a coerced/defaulted/preprocessed
      # input resolves the value the worker would see with no eager pass — the same lazy behavior model:
      # readers already relied on here. This just clears any pre-pipeline memo so those reads resolve
      # against the settled inputs. Deliberately does NOT validate (a report on already-dead work must
      # never raise) and does NOT run the action. Any failure is swallowed — a partially-prepared
      # instance still yields more facets than a bare one.
      def prepare_inbound_for_facets!
        Axn::Extensions.best_effort("preparing inbound context for async facet resolution", action: @action) do
          _clear_pre_pipeline_memos!
        end
      end

      # Input-phase facet resolution for enqueue-time sinks (e.g. Sidekiq job tags), where there is
      # no run to hang completion-time resolution on. Resolves only `from: :inputs` facets (via the
      # memoized resolved_input_* readers) against the RAW enqueued inputs. It deliberately does NOT
      # run preprocess/defaults: those are user hooks that must execute once, at perform — a dynamic
      # `default:`/`preprocess:` run here would both double-execute (enqueue AND perform) and compute
      # a value that can differ from the run, so the facet would drift from its own job. Resolving
      # from raw inputs keeps the facet in lockstep with the serialized payload the worker receives.
      # `from: :result` facets are excluded by construction (they can't resolve before the body runs);
      # a `model:` field's record still loads lazily (facade.rb) if a resolver reads it. Returns one
      # resolved map per enabled source (tags, then dimensions), kept SEPARATE so a name declared as
      # both a tag and a dimension yields two facets rather than one clobbering the other. `sources`
      # is a subset of %i[tag dimension]. See PRO-2855.
      def resolve_inbound_facets(sources)
        # Resolve readers in raw mode (ContractForSubfields.resolve_value): a facet reading an input sees the
        # raw serialized value, not the coerced/preprocessed/defaulted run-time value, so it stays in lockstep
        # with the payload the worker receives and a dynamic hook is not run at enqueue.
        @action.instance_variable_set(:@__resolve_raw_reads, true)
        maps = []
        maps << resolved_input_tags if sources.include?(:tag)
        maps << resolved_input_dimensions if sources.include?(:dimension)
        maps
      ensure
        @action.remove_instance_variable(:@__resolve_raw_reads) if @action.instance_variable_defined?(:@__resolve_raw_reads)
      end

      private

      # =========================================================================
      # TRACING (Outside zone - result is settled)
      # =========================================================================
      #
      # Tracing calls an object the APP supplies, inside the hot path, so the failure space is the
      # grid below rather than the happy path plus whatever went wrong last. Every cell holds one
      # invariant: tracing may neither suppress, duplicate, nor replace the action. Each is exercised
      # by spec/axn/configuration/tracer_spec.rb; add the cell here before adding the guard.
      #
      #   FAILURE POINT              x  UNWIND: return / swallowable raise / signal / throw
      #   ------------------------------------------------------------------------------------
      #   resolving the action's name   propagate it untouched — it happens before any observer, so
      #                                 there is nothing to trace and nothing this method's ensure may
      #                                 put in its place
      #   resolving Axn.config.tracer   log, run the action untraced
      #   probing #in_span              treat as unsupported; never let the probe escape
      #   entering in_span              log, run untraced
      #   before yield                  log, run untraced (the action has NOT run yet)
      #   returns without yielding      run untraced — no exception, so absence of one proves nothing
      #   yields more than once         run the action for the FIRST yield only
      #   after yield                   log and keep the settled result; the action already ran
      #   completion-side hook (log_after, the timing ensure) runs inside the action's own block but
      #                                 after the result settled — an unwind there is a side channel
      #                                 failing on its way out, so keep the settled result
      #   span finalization             skip it unless the action ran inside that span
      #   span missing an optional method  attempt the call and tolerate absence; never ask
      #                                   respond_to?, which a proxy cannot answer or answers wrongly
      #   notification start            run the action bare; do not re-enter a notification that ran
      #   notification finish           log; the action already ran and settled
      #   stores the block and invokes it after this boundary exits — refuse it. On a cancellation
      #                                 path both claims are deliberately left un-taken, so identity
      #                                 alone would admit a deferred callback on the caller's own
      #                                 thread and commit work the caller had abandoned
      #
      # Signals and throws are the exception to all of it: the caller has abandoned the call, so they
      # escape without the action being started. See `resumable_after?`.
      #
      # The dispatch count is a property of this LAYERING, not of any one re-raise: every nested
      # rescue-and-re-raise on the unwind path asks the exception for itself once more. A cancellation
      # currently passes four of them (exception handling declining to settle it, `execute` recording
      # it, `observe` recording it, and the guard below) against one for a bare `raise`/`rescue` pair,
      # so each layer added here costs another substitution opportunity for the class of exception
      # described above. Recording WHERE an unwind happened is why the layers exist, so this is a price
      # rather than a defect — but it is worth knowing before adding a fifth.
      #
      # An observer RETURNING is not proof the stack it wrapped succeeded: a tracer may rescue around
      # its own `yield`. The wrapped stack's exception is kept, not just flagged, and re-raised after
      # the observer returns if the observer absorbed it.
      #
      # One limit is worth stating, because the guarantee below reads stronger than Ruby allows. Ruby
      # asks an exception INSTANCE for itself on every raise — `raise` with no argument does this as
      # surely as `raise e` — so an exception class defining a stateful or hostile `#exception` can
      # answer with a different object when axn re-raises it, and the action's failure is replaced
      # despite everything here. There is no re-raise form that skips that dispatch, and wrapping the
      # exception instead would change the class every well-behaved caller rescues in order to defend
      # against one that has already subverted `raise` process-wide, at its own original raise site.
      # So this path preserves the action's failure against observers, not against the exception itself.
      #
      # And the guard covers TRACING's failures only. `with_logging` and `with_timing` run inside this
      # block but outside `with_exception_handling`, so an error there is never settled onto the
      # result; absorbing it would report a default success for an action that never ran. Errors
      # reaching here out of `block.call` are re-raised — see `inner_failed`.

      def with_tracing(&block)
        # The action, separable from every observer of it. `ActionAttempt` records what happened to it
        # — begun, raised, abandoned — where it actually happens, rather than letting a wrapper's own
        # progress stand in for the action's.
        #
        # Constructed BEFORE any fallible setup, because the ensure below closes it: resolving the
        # resource name runs user-overridable code and can raise, and an ensure that assumes a local
        # from further down the method replaces that failure with a NoMethodError about its own
        # bookkeeping. Nothing here can fail — current thread and fiber, a mutex, and a bound method.
        attempt = ActionAttempt.new(settled: method(:action_result_finalized?))

        resource = @action_class.resolved_axn_name
        payload = { resource:, action: @action }

        update_payload = proc do
          Axn::Extensions.best_effort("updating notification payload while tracing axn.call", action: @action) do
            result = @action.result
            outcome = result.outcome.to_s
            payload[:outcome] = outcome
            payload[:result] = result
            payload[:elapsed_time] = result.elapsed_time
            payload[:exception] = result.exception if result.exception
            payload[:tags] = Core::Tagging.dup_facets(resolved_tags) if @action_class._tags.any?
            payload[:dimensions] = Core::Tagging.dup_facets(resolved_dimensions) if @action_class._dimensions.any?
          end
        end

        run_action = proc do
          attempt.require_originating_context!
          attempt.execute { block.call } if attempt.claim
        end

        # Enrich the payload from inside the instrument block — after the action settles but
        # BEFORE ActiveSupport publishes the event — so live `axn.call` subscribers observe the
        # full payload. Running update_payload after `instrument` returns (its own ensure) would
        # publish first and mutate after, leaving subscribers with outcome/result/tags/dimensions
        # missing at callback time.
        #
        # Notification is a side channel like tracing, and `instrument` can raise BEFORE it yields — an
        # evented `axn.call` subscriber whose `start` callback blows up does exactly that, so the action
        # would never be reached. That is why the last-resort fallback below calls `run_action` rather
        # than this: once notification has failed, retrying it fails the same way.
        instrument_block = proc do
          # Wrapped in `observe` so an unwind through NOTIFICATION startup is recorded too. A
          # subscriber can `throw` or raise a signal from its `start` callback, before `run_action` is
          # ever reached — and a tracer that catches around its yield then absorbs it, leaving the
          # attempt with nothing recorded and the fallback free to run the action. Turning a
          # cancellation into committed work is the outcome worth the most care to avoid.
          attempt.observe do
            ActiveSupport::Notifications.instrument("axn.call", payload) do
              run_action.call
            ensure
              update_payload.call
            end
          end
        end

        # Guards notification delivery, NOT the stack it wraps — same rule as the tracing boundary
        # below, and it has to be restated here because this proc reaches `block.call` too. Absorbing
        # a wrapped-stack failure would leave the attempt started, skip the bare fallback, and return
        # the action's unfinalized default-success result.
        emit_notification = proc { guarding_observer("emitting axn.call notification", attempt) { instrument_block.call } }

        # ONE boundary around everything tracing does — resolving the tracer, probing its signature,
        # opening the span, finalizing it. All of it is a side channel, and the whole path holds a
        # single invariant: it may neither suppress, duplicate, nor replace the action.
        #
        # `attempt.started?` (set where the action actually begins) is the entire guarantee. It makes the
        # action run at most once no matter how the tracer behaves — raising before yielding, returning
        # without ever yielding (a disabled or broken decorator), yielding more than once, or raising
        # afterward — and anything that leaves this boundary with it still false means the action has
        # not run, so the untraced fallback owes it exactly one execution.
        #
        # The fallback lives in `ensure` deliberately: `best_effort` re-raises under
        # `best_effort_raises_in_dev`, and a dev-loud tracing error must still not cost the action its
        # run. Same reason an exception axn never swallows reaches the fallback on its way past.
        #
        # A failure anywhere in here belongs to tracing, never to the action: `with_exception_handling`
        # runs INSIDE this block (see #run), so the action's own swallowable exceptions are already
        # settled onto its result before control returns. Presence of a TRACER — not of the
        # OpenTelemetry constant — is what gates the span, so an explicitly configured tracer works
        # with OpenTelemetry unloaded and `tracer = nil` turns spans off with it loaded.
        traced = nil
        begin
          guarding_observer("tracing axn.call", attempt) do
            emit_observed(resource, instrument_block, attempt)
          end
          traced = :returned
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
          traced = :absorbable_error
          raise
        ensure
          # Reached only when nothing above managed to start the action — a tracer that never yielded,
          # a notification subscriber that raised before it, a dev-loud re-raise on its way past. Shed
          # observers one at a time rather than all at once: the span may be what broke, in which case
          # the notification is still worth emitting, and only if that fails too does the action run
          # bare. Losing both is a smaller failure than losing the caller's work.
          #
          # Unless the caller has already given up. Each guarded step records how IT ended, rather than
          # anything reading ambient state: a `Timeout` from an enclosing block, an `Interrupt`, an
          # `exit`, or a `throw` must escape here rather than start the action, since work that runs —
          # and possibly commits — after its caller was cancelled is worse than a lost span.
          if may_start_action?(attempt, traced)
            emitted = nil
            begin
              # Only when nothing claimed the notification — a tracer that raised or returned before
              # yielding. If it WAS claimed and still left the action unstarted, the failure is the
              # notification's own, and re-entering it would repeat whatever a subscriber already did
              # before raising.
              emit_notification.call if attempt.claim_notification
              emitted = :returned
            rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
              emitted = :absorbable_error
              raise
            ensure
              run_action.call if may_start_action?(attempt, emitted)
            end
          end
        end
      ensure
        # The attempt does not outlive the boundary. Every path that may legitimately run the action
        # has been taken by the time this runs — including the untraced fallback above — so anything
        # reaching for it after this point is a tracer invoking a block it stored, and must find both
        # claims closed rather than merely un-taken.
        #
        # `&.` because this ensure covers the WHOLE method body, construction included: an ensure that
        # assumes its locals were assigned is how bookkeeping replaces the failure it was meant to
        # survive. Nothing to close means nothing was ever handed out.
        attempt&.close!

        # Same reasoning as the `&.` above, for the other local this ensure reads. `resolved_axn_name`
        # never returns nil (it falls back to ANONYMOUS), so a nil resource means resolving it RAISED
        # and the assignment never happened — there is no action identity to file a metric under, and
        # `best_effort` re-raises under best_effort_raises_in_dev, which would put a metrics error in
        # place of the failure that got us here.
        # `action_result_finalized?` for the same reason span finalization and completion logging gate
        # on it: an unfinalized result still reads its default `success`, so emitting here would record
        # a successful action that never ran. Reached exactly that way — a tracer raising `Interrupt`
        # or throwing before it yields leaves the action unstarted while this ensure still runs, and the
        # metric outlives the cancellation that follows it.
        emit_metrics_for(resource) if resource && action_result_finalized?
      end

      def emit_metrics_for(resource)
        Axn::Extensions.best_effort("calling emit_metrics while tracing axn.call", action: @action) do
          emit_metrics_proc = Axn.config.emit_metrics
          next unless emit_metrics_proc

          result = @action.result
          Internal::Callable.call_with_desired_shape(emit_metrics_proc,
                                                     kwargs: { resource:, result:, dimensions: Core::Tagging.dup_facets(resolved_dimensions) })
        end
      end

      # The attempt's view of whether the action's result has SETTLED. Same `finalized?` signal
      # `log_after` gates on — true on every settling path, false for a body that never reached the
      # exception boundary.
      def action_result_finalized? = @action.result.finalized?

      # Runs an observer (the span, the notification) so its OWN failure is logged and swallowed while
      # a failure of the stack it wraps escapes untouched. Both callers reach `block.call` through the
      # observer, and `with_logging`/`with_timing` sit inside that but outside `with_exception_handling`
      # — so an error from there is never settled onto the result, and absorbing it would return a
      # default success for an action that never ran.
      def guarding_observer(description, attempt)
        begin
          yield
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
          recorded = attempt.error
          # `raise recorded`, never a bare `raise`: an observer that catches the wrapped stack's
          # failure and raises its OWN in response (an exporter dying while recording an exception)
          # would otherwise replace the call's real outcome with a side-channel error. The observer's
          # is logged like any other observer failure; the action's is the one that propagates.
          if recorded
            begin
              # `ensure`, because best_effort RE-RAISES under best_effort_raises_in_dev — and letting
              # the observer's error win there would undo the whole point of preferring the recorded
              # one, in the environment where a developer is most likely to be running.
              Axn::Extensions.best_effort(description, action: @action) { raise e } unless Internal::Identity.same?(e, recorded)
            ensure
              raise recorded
            end
          end

          Axn::Extensions.best_effort(description, action: @action) { raise e }
        rescue Exception => e # rubocop:disable Lint/RescueException
          # A class axn never swallows, so it is never logged or absorbed here — but it can still be a
          # REPLACEMENT: a tracer that catches the action's `Interrupt` and raises its own `SystemExit`
          # would otherwise carry the observer's cancellation out in place of the action's, skipping
          # the clause above entirely because neither class is swallowable.
          recorded = attempt.error
          raise recorded if recorded && !Internal::Identity.same?(e, recorded)

          raise
        end

        # The observer returned — but returning is not proof the stack it wrapped succeeded. A tracer
        # may rescue around its own `yield` (recording the exception is a reason to), absorbing a
        # failure that never reached the rescue above. Surface it rather than letting the observer
        # decide the call's outcome.
        swallowed = attempt.error
        raise swallowed if swallowed
        return unless attempt.abandoned?

        # The stack unwound by `throw` and the observer consumed it. The tag and value are unrecoverable,
        # so the cancellation cannot be re-thrown — but reporting a success for an action that never
        # finished is worse than failing loudly about it.
        raise "#{description}: absorbed a non-local exit from the action, which therefore did not " \
              "complete. A tracer or subscriber must not `catch` around the block axn hands it."
      end

      # Whether this path may still start the action. Not started yet, nothing has abandoned it, and
      # the guarded step either returned normally or is unwinding an error axn may absorb. `abandoned?`
      # bars it as firmly as a signal does: the stack unwound by a `throw` somewhere an observer
      # swallowed it, so the caller is gone and running the action now would turn a cancellation into
      # committed work.
      def may_start_action?(attempt, returned_normally)
        !attempt.started? && !attempt.abandoned? && resumable_after?(returned_normally)
      end

      # Whether it is still legitimate to do more work on the action's behalf. Takes the guarded step's
      # OWN record of having returned normally rather than inferring it: an absent `$!` does not mean
      # nothing went wrong, because a `throw` unwinds with no exception in flight at all. So
      # resumability is either an observed normal return, or an error axn may absorb propagating (the
      # dev-loud path). A signal or a `throw` is neither, and must not be answered by starting the
      # action — the caller has abandoned this call.
      # `outcome` is what the guarded step RECORDED about its own ending, never a reading of ambient
      # state. `$!` cannot answer this: entering `.call` from inside a `rescue` handler leaves the
      # previously-handled error there for the duration, so a `throw` unwinding past this point looks
      # identical to an absorbable error — and the action would be started after its caller had
      # already abandoned the call.
      def resumable_after?(outcome)
        %i[returned absorbable_error].include?(outcome)
      end

      # Emits the `axn.call` span and notification around the action. Split out of `with_tracing` so the
      # invariant there — the action runs exactly once, whatever the observers do — reads as one piece.
      # `started_check` is how the double-yield guard sees a flag owned by the caller's closure.
      def emit_observed(resource, instrument_block, attempt)
        tracer = Axn.config.tracer
        unless tracer
          instrument_block.call if attempt.claim_notification
          return
        end

        in_span_kwargs = { attributes: { "axn.resource" => resource } }
        in_span_kwargs[:record_exception] = false if Internal::Tracing.supports_record_exception_option?(tracer)

        tracer.in_span("axn.call", **in_span_kwargs) do |span|
          # Refuse the WHOLE off-context block, not just the action inside it. Subscribers are user
          # code too: letting an off-context block claim the notification runs every `axn.call`
          # subscriber with an empty axn execution context, and possibly still running after `.call`
          # has returned — the action being refused a moment later does not undo that.
          next unless attempt.originating_context?

          # Claims the NOTIFICATION, so a tracer yielding more than once emits `axn.call` exactly once
          # and finalizes exactly one span. The action itself is claimed separately, inside
          # `run_action`, immediately before it begins.
          next unless attempt.claim_notification

          begin
            instrument_block.call
          ensure
            # Only describe a span the action actually ran inside. If `instrument` exited before
            # reaching the action — an evented subscriber raising or throwing from `start` — the result
            # is still at its default `success`, so finalizing here would stamp a completed success
            # onto a call that went on to fail in the observer-free fallback, or never ran at all. An
            # unlabelled span is a smaller lie than a wrong one.
            # `settled?`, not `started?`: a stack that begins and aborts before the exception boundary
            # never settles its result, which still reads the default `success` — describing that
            # would report a completed success for a call that failed.
            #
            # And `settled?` rather than "the block returned normally", because those diverge. A throw
            # from the completion side — `log_after`, the timing ensure — unwinds a call whose result
            # already finalized, which `execute` deliberately does not treat as abandonment. That call
            # returns its settled result, so its span has a real outcome to carry and skipping it would
            # leave an unlabelled span on a perfectly good call.
            #
            # `originating_context?` is belt here (the guard above already refused an off-context
            # block) and states the property directly: this span describes an action that ran inside
            # it, never one the fallback ran elsewhere.
            # Through `observe`, so a signal raised by the span's own methods is recorded: `finalize_span`
            # guards itself with best_effort, which by design does not swallow a class axn never
            # swallows — and a tracer wrapping its yield in `rescue Exception` would otherwise absorb
            # that signal and hand back the settled success.
            attempt.observe { finalize_span(span) } if attempt.settled? && attempt.originating_context?
          end
        end
      end

      def finalize_span(span)
        Axn::Extensions.best_effort("updating OTel span while tracing axn.call", action: @action) do
          result = @action.result
          outcome = result.outcome.to_s
          span.set_attribute("axn.outcome", outcome)

          if %w[failure exception].include?(outcome) && result.exception
            # Recording error details is OpenTelemetry-shaped: `set_attribute` is all a configured
            # tracer's span is asked for, so both calls below are conditional, and the pair is isolated
            # in its own best_effort. Otherwise a span that omits one — or raises inside it — aborts the
            # enclosing block and silently drops the facet attributes set afterward.
            #
            # `record_exception` is ATTEMPTED rather than capability-checked: its argument is a plain
            # Ruby exception any span can do something sensible with, and asking `respond_to?` first
            # would lose the event for a span that cannot answer — a BasicObject-based proxy has no
            # `respond_to?` at all, and one that overrides it can answer wrongly. A span that genuinely
            # lacks the method is the only thing the rescue absorbs.
            #
            # A STATUS cannot be offered the same way: the only status axn can construct is an
            # `OpenTelemetry::Trace::Status`, so the test is whether the span IS an OpenTelemetry span,
            # not whether it answers `status=`. A custom span exposing that name means its OWN status
            # type, and handing it a vendor object would store a value it never agreed to. It keeps the
            # recorded exception instead.
            Axn::Extensions.best_effort("recording exception details on the axn.call span", action: @action) do
              begin
                span.record_exception(result.exception)
              rescue NoMethodError => e
                # Only a genuinely ABSENT method. A NoMethodError raised from INSIDE a working
                # `record_exception` is that span's own bug, and swallowing it here would hide it from
                # the guard — including from the dev-loud path, where it should be raised like any
                # other tracing failure.
                raise unless e.name == :record_exception && Internal::Identity.same?(e.receiver, span)

                nil
              end

              # `Module#===`, not `span.is_a?`: the span is caller-supplied, and a proxy answering
              # `is_a?` however it likes must not be able to talk its way into a vendor status object.
              if defined?(OpenTelemetry::Trace::Status) && defined?(OpenTelemetry::Trace::Span) &&
                 Axn::Internal::Identity.kind?(span, OpenTelemetry::Trace::Span)
                error_message = Internal::Rendering.exception_message(result.exception)
                span.status = OpenTelemetry::Trace::Status.error(error_message)
              end
            end
          end

          resolved_tags.each { |name, value| span.set_attribute("axn.tag.#{name}", value) }
          resolved_dimensions.each { |name, value| span.set_attribute("axn.dimension.#{name}", value) }
        end
      end

      # Facets resolve in two phases (see Core::Tagging::Facet): input-phase facets resolve from
      # inputs (eagerly, before the body — so they can annotate in-flight logs), result-phase facets
      # resolve at settle. Each phase is memoized and resolved once; the settle-time sinks (span,
      # payload, emit_metrics, completion-line log) read the merged view.
      def resolved_tags = @resolved_tags ||= resolved_input_tags.merge(resolved_result_tags)
      def resolved_dimensions = @resolved_dimensions ||= resolved_input_dimensions.merge(resolved_result_dimensions)

      # Build a declared facet map for the exception report. REUSE the pre-body input-phase snapshot
      # (`input_snapshot`, memoized in with_facet_log_context before `call`) so the report matches the
      # value the span/payload/logs captured — even if the body then mutated an input. Resolve only the
      # RESULT-phase facets freshly here, and deliberately NOT through the memoized resolved_result_*:
      # trigger_on_exception runs inside with_timing, before its ensure sets result.elapsed_time, so
      # memoizing now would freeze a result-phase facet reading elapsed_time as nil and poison those
      # post-timing sinks. dup the whole merge so a reporter mutating a value can't corrupt the shared
      # input snapshot the other sinks read (the fresh result-phase values are already private).
      def resolve_report_facets(input_snapshot, map)
        return {} unless map.any?

        Core::Tagging.dup_facets(input_snapshot.merge(Core::Tagging.resolve(map, action: @action, from: :result)))
      end

      def resolved_input_tags = @resolved_input_tags ||= _resolve_facets(@action_class._tags, :inputs)
      def resolved_result_tags = @resolved_result_tags ||= _resolve_facets(@action_class._tags, :result)
      def resolved_input_dimensions = @resolved_input_dimensions ||= _resolve_facets(@action_class._dimensions, :inputs)
      def resolved_result_dimensions = @resolved_result_dimensions ||= _resolve_facets(@action_class._dimensions, :result)

      def _resolve_facets(facets, from)
        facets.any? ? Core::Tagging.resolve(facets, action: @action, from:) : {}
      end

      # =========================================================================
      # LOGGING (Outside zone - result is settled)
      # =========================================================================

      # Both hooks are guarded HERE, not only inside CallLogger#log_at_level: everything used to build a
      # line — the duration, the facet maps, the separator, the context slices — is an ARGUMENT to that
      # inner guard, so it is evaluated outside it. A raise from any of them escapes, and from this
      # `ensure` it would REPLACE the exception already in flight: an enclosing Timeout's ExitException
      # (which then never reaches the handler that converts it to Timeout::Error, so the timeout silently
      # does not fire), or a Ctrl-C, reported instead as an unrelated error from the log formatter.
      def with_logging
        Axn::Extensions.best_effort("logging before hook", action: @action_class) { log_before } if @action_class._auto_log_before_level
        yield
      ensure
        Axn::Extensions.best_effort("logging after hook", action: @action_class) { log_after }
      end

      def log_before
        Internal::CallLogger.log_at_level(
          @action_class,
          level: @action_class._auto_log_before_level,
          message_parts: ["About to execute"],
          join_string: " with: ",
          before: top_level_separator,
          error_context: "logging before hook",
          context_direction: :inbound,
          context_instance: @action,
        )
      end

      def log_after
        # Only a run that SETTLED has a completion to report. `finalized?` is that exact signal — every
        # settling path sets it (success, `fail!`, `done!`, a recorded exception) — and it is false in the
        # two cases that reach this ensure without one: a pass-through abort (an Interrupt or Timeout
        # signal, which axn deliberately leaves untouched) and a body that never started, when a
        # non-StandardError escaped `log_before`. Reporting either would state an outcome that never
        # happened — the unsettled result reads `success` — and formatting a nil duration would raise out
        # of this ensure, replacing the exception in flight.
        return unless @action.result.finalized?

        level = @action_class._auto_log_level_for(@action.result.outcome)
        return unless level

        log_after_at_level(level)
      end

      def log_after_at_level(level)
        Internal::CallLogger.log_at_level(
          @action_class,
          level:,
          message_parts: [
            "Execution completed (with outcome: #{@action.result.outcome}) in #{Internal::Timing.human_duration(@action.result.elapsed_time)}",
          ],
          join_string: ". Set: ",
          after: top_level_separator,
          error_context: "logging after hook",
          context_direction: :outbound,
          context_instance: @action,
          facets: log_facets,
        )
      end

      # Copies (never the memoized maps) of the resolved facets for the log sink, so a suffix/tagged
      # annotation can never mutate what the span / payload / emit_metrics sinks share. Omitted
      # entirely when nothing is declared, so an action with no facets does zero extra work here.
      def log_facets
        return nil unless @action_class._tags.any? || @action_class._dimensions.any?

        {
          tags: Core::Tagging.dup_facets(resolved_tags),
          dimensions: Core::Tagging.dup_facets(resolved_dimensions),
        }
      end

      def top_level_separator
        return if Axn.config.env.production?
        return if Util::ExecutionContext.background?
        return if Util::ExecutionContext.console?
        return if Core::NestingTracking._current_axn_stack.size > 1

        "\n------\n"
      end

      # =========================================================================
      # TIMING (Inside zone - sets elapsed_time)
      # =========================================================================

      def with_timing
        timing_start = Internal::Timing.now
        yield
      ensure
        # No start means the clock read itself was interrupted, so there is no duration to record —
        # measuring against nil would raise out of this ensure and replace the exception in flight.
        # `log_after` treats a nil elapsed_time as "the body never ran" and stays quiet.
        if timing_start
          elapsed_mils = Internal::Timing.elapsed_ms(timing_start)
          @context.send(:elapsed_time=, elapsed_mils)
        end
      end

      # =========================================================================
      # EXCEPTION HANDLING (Boundary)
      # =========================================================================

      def with_exception_handling
        yield
      rescue Internal::EarlyCompletion
        raise
      rescue StandardError => e
        _settle_exception(e)
      rescue Exception => e # rubocop:disable Lint/RescueException
        # An exception from OUTSIDE StandardError is still a bug in the run — a SystemStackError from
        # runaway recursion, a NotImplementedError from an unfinished method — reachable from anywhere
        # user code runs (the body, any hook, a `preprocess:`/`coerce:`/`default:` callable — but not a
        # `validate:` one, whose own guard turns any raise into that field's validation message).
        # Nothing rescued those, so the run settled as nothing at all: `outcome` read `success`, the
        # completion line said so, the global report never fired, and it escaped `.call` — breaking the
        # consistent-return guarantee that only `call!` opts out of.
        #
        # So settle it exactly like a StandardError bug — an `exception` outcome `.call` RETURNS, with
        # on_error + on_exception fired, one global report, and `fails_on` honored the same way (see
        # Flow::FailsOn, which rejects at declaration any class this gate would never let through).
        # `call!` still raises it from its own `raise result.exception`, the original object.
        #
        # Gated on an ALLOWLIST (see Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR), so anything axn does
        # not positively recognize as a bug passes through untouched: a signal, an `exit`, or another
        # library's private control-flow signal, which absorbing into a result would silently break.
        raise unless Axn::Extensions.swallowable?(e)

        _settle_exception(e)
      end

      # The one path by which an exception settles onto the result.
      #
      # Guarded because it runs USER code — an on_error/on_failure callback, a matcher, error-message
      # resolution — from inside a rescue clause, where a raise does NOT reach the sibling
      # `rescue Exception` above: it would escape `.call` AND replace the very exception being settled,
      # so the caller would see a stack overflow from someone's callback instead of the real failure.
      # A swallowable one is therefore warned and dropped; `__record_exception` has already run by then,
      # so the result still settles on the original exception. Anything not swallowable still propagates.
      def _settle_exception(settling)
        _settle_exception!(settling)
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise unless Axn::Extensions.swallowable?(e)

        Axn::Extensions.best_effort("settling #{Internal::Rendering.class_name(settling)} onto the result", action: @action) { raise e }
      end

      def _settle_exception!(e)
        # Outbound defaults let the caller (and an on_error handler) read sensible exposures off a failed
        # result. Swallow-all deliberately: the block's failure only costs a default value on an
        # already-failed result, so it must never change control flow — letting a user `default:` proc
        # that blows the stack escape from here would break the same `.call` guarantee.
        Axn::Extensions.best_effort("applying outbound defaults on failure", action: @action) do
          apply_defaults!(:outbound)
        end

        @context.__record_exception(e)

        # Resolve + stamp the presentation BEFORE dispatching any callbacks, so an on_error/on_failure
        # filter or body that reads exception.message observes the same resolved string as result.error
        # and the call!-raised exception — not the raw reason. (Context is finalized by __record_exception
        # above, so result.error memoizes here.)
        _resolve_and_stamp_presentation(e)

        @action_class._dispatch_callbacks(:error, action: @action, exception: e)

        if e.is_a?(Failure) || @action_class._fails_on?(e) || Internal::ExceptionClassification.failure?(e) ||
           Axn::ValidationError.user_facing?(e)
          # Make a `fails_on` (or user-facing `expects ..., user_facing:`) classification sticky to this
          # exception object (per call tree), so it stays a failure (fires on_failure, no report) as it
          # propagates through ancestor `call!`s — mirroring how Axn::Failure is sticky via its class.
          # Also record it on this result's context so result.outcome reports `failure` after the
          # per-execution set is cleared.
          Internal::ExceptionClassification.mark_failure!(e) unless e.is_a?(Failure)
          @context.__classify_as_failure!
          @action_class._dispatch_callbacks(:failure, action: @action, exception: e)
        else
          trigger_on_exception(e)
        end
      end

      # Resolve THIS level's presentation NOW (memoizing it on the result) and, for an Axn-owned
      # exception, stamp it onto #message so a rescued exception reads the same string as result.error.
      #
      # The eager resolution matters even when nothing is stamped: it must happen while this action is
      # still on the nesting stack, because an ancestor's `call!` carried the child's presentation in
      # CarriedPresentation, which is cleared when the stack empties. Resolving (and memoizing) here
      # freezes the aggregated value before that reset; a later lazy read would find the carry gone.
      #
      # The cross-level CARRY itself is set by `call!`, not here — it must be scoped to transparent
      # `call!` bubbling. Setting it at every level would leave a presentation on a child run via plain
      # `.call`, which an explicit `.call` + re-raise (e.g. `step`'s bug path, `raise step_result.exception`)
      # would then leak into the parent's aggregation.
      def _resolve_and_stamp_presentation(exception)
        resolved = @action.result.error
        return unless resolved && Axn.owns_failure_exception?(exception) && exception.respond_to?(:__present_as)

        exception.__present_as(resolved)
      end

      def trigger_on_exception(exception)
        Axn::Extensions.best_effort("executing on_exception hooks", action: @action) do
          retry_context = Async::CurrentRetryContext.current if defined?(Async::CurrentRetryContext)
          if retry_context
            mode = @action_class.try(:_async_exception_reporting)
            return unless retry_context.should_trigger_on_exception?(mode)
          end

          # Per-action :exception callbacks fire at each level (an action may legitimately observe its
          # own failure), but the GLOBAL report is sent at most once per exception, at the INNERMOST action
          # that treats it as a bug (where the failing action and full nesting stack are still live). A
          # nested `call!` re-raises the same object up the stack; the `reported?` guard stops each ancestor
          # from reporting it again.
          @action_class._dispatch_callbacks(:exception, action: @action, exception:)
          return if Internal::ExceptionClassification.reported?(exception)

          # Mark BEFORE attempting, so the report is best-effort EXACTLY once: if on_exception (or building
          # its context) raises, best_effort swallows and logs it and it is NOT retried from an ancestor
          # (which would describe the wrong action anyway). Deterministic regardless of nesting depth.
          Internal::ExceptionClassification.mark_reported!(exception)

          context = Internal::ExceptionContext.build(
            action: @action,
            retry_context:,
            # Pre-body input snapshot (memoized) + freshly-resolved result-phase facets; see resolve_report_facets.
            tags: resolve_report_facets(resolved_input_tags, @action_class._tags),
            dimensions: resolve_report_facets(resolved_input_dimensions, @action_class._dimensions),
          )
          Axn.config.on_exception(exception, action: @action, context:)

          # Mark reported only AFTER the global report succeeds. If `build`/`on_exception` raises,
          # best_effort swallows it and nothing is marked here — so an ancestor executor still attempts
          # the report rather than seeing `reported?` and dropping the exception entirely.
          Internal::ExceptionClassification.mark_reported!(exception)
        end
      end

      # =========================================================================
      # CONTRACT (Inside zone)
      # =========================================================================

      def with_contract(&block)
        # Take sole ownership of any per-call gates set by the caller (e.g. Axn::Tools::Invoker),
        # clearing the holder so a nested `.call` in the body runs with default semantics. Stash the
        # consumed Options on the action instance (where per-call state lives) so the read-path
        # coercion honors the same gate this executor's validation-message path reads.
        #
        # Two copies, deliberately not unified: the action-anchored copy is the only one reachable from
        # ContractForSubfields' read-path coercion (it has just the action, not this executor), while the
        # boolean gates below are read only from this executor, off its own copy.
        @__call_options = Internal::CurrentCallOptions.consume
        @action.instance_variable_set(:@__call_options, @__call_options) if @__call_options

        # A pre-pipeline read — a hook/preprocess touching a reader (which may consult a sibling's
        # value-level default via resolve_model_via_id) — can populate both
        # ContractForSubfields' @__resolve_value_cache AND a reader's own memo before inbound validation
        # runs. The settled inputs are the authoritative state, so discard any pre-pipeline cache: the
        # validation-time reads below then resolve against the settled wire values.
        _clear_pre_pipeline_memos!

        # Top-level and subfield coerce:/preprocess:/default: resolve lazily on the read path
        # (ContractForSubfields.resolve_value), first triggered as inbound validation reads each reader —
        # never eagerly written back into provided_data. A `done!` raised inside a preprocess/default
        # therefore surfaces here, during validation, so this read is wrapped to settle the early
        # completion.
        return if handle_early_completion_if_raised { validate_contract!(:inbound) }

        # Inputs are canonical here (preprocessed, defaulted, validated), so input-phase facets can
        # resolve — wrap the body so in-flight log lines inherit them under a SemanticLogger.
        if handle_early_completion_if_raised { with_facet_log_context(&block) }
          apply_defaults!(:outbound)
          validate_contract!(:outbound)
          return
        end

        # The outbound copy-forward reads expects+exposes fields through the read path, which can be the
        # first time a field's default:/preprocess: runs; a done! raised there settles the same early
        # completion as one raised during validation or the body, rather than escaping .call.
        return if handle_early_completion_if_raised do
          apply_defaults!(:outbound)
          validate_contract!(:outbound)
        end

        @context.__finalize!
        trigger_on_success
      end

      # Resolve input-phase facets here — after inbound validation, before the body — so their values
      # reflect pre-body inputs. This happens unconditionally (memoized, reused by the settle-time
      # sinks), so the phase contract holds regardless of logger: without this, a plain-logger run
      # would first resolve them later at the completion sinks, making a mutable input's value depend
      # on the logger. Then, only if the configured logger is a SemanticLogger, wrap the body in a
      # tagged context so every log line emitted during `call` is annotated (axn.tag.<name> /
      # axn.dimension.<name>). Result-phase facets aren't available yet — they only annotate the
      # settle-time completion line.
      def with_facet_log_context(&body)
        return body.call unless @action_class._tags.any? || @action_class._dimensions.any?

        named = Core::Tagging.namespaced(tags: resolved_input_tags, dimensions: resolved_input_dimensions)
        return body.call unless named.any? && Internal::CallLogger.semantic_logger?

        SemanticLogger.tagged(**named, &body)
      end

      def handle_early_completion_if_raised
        yield
        false
      rescue Internal::EarlyCompletion => e
        @context.__record_early_completion(e.message, standalone: e.standalone)
        trigger_on_success
        true
      end

      # With coerce_input_types resolved on, surface `coerce: true` in the type bag for a coercible field
      # that didn't set `coerce:` explicitly, so TypeValidator emits the "could not be coerced" message on
      # a parse failure exactly as for an explicit `coerce:` field. Message-only — the coercion itself
      # resolves on the read path (ContractForSubfields.resolve_value); this returns a copy and never
      # mutates the shared config. A field with an explicit coerce flag (true or false) is left as-is,
      # so field-level intent wins.
      def _with_effective_coerce(field_validations)
        type_opt = field_validations[:type]
        return field_validations if type_opt.nil?
        return field_validations if type_opt.is_a?(Hash) && type_opt.key?(:coerce)
        return field_validations if Axn::Reflection::Coercion.coercible_klasses(type_opt).empty?

        type_hash = type_opt.is_a?(Hash) ? type_opt : { klass: type_opt }
        field_validations.merge(type: type_hash.merge(coerce: true))
      end

      def validate_contract!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        return _validate_inbound! if direction == :inbound

        failures = @action_class.send(:external_field_configs).filter_map do |config|
          errors = Axn::Validation::Fields.collect_errors(field: config.field, validations: config.validations,
                                                          source: @action.result, action: @action)
          ContractFailure.new(config:, path: nil, errors:, stranded_at: nil) if errors.any?
        end
        raise OutboundValidationError, _aggregate_errors(failures, []) if failures.any?
      end

      # Inbound validation has three sources — declared fields at every depth, plus model consistency —
      # and runs collect-then-settle: EVERY config's errors are collected first (one uniform per-config
      # pass over both stores, then model-consistency mismatches), stranded checks are pruned with
      # complete failure knowledge, and the survivors settle once. Classification follows each failing
      # config's own `user_facing:` at any depth; model-consistency mismatches are structurally
      # dev-facing. The settling rule: any dev-facing violation dominates and the whole (unsuppressed)
      # violation set raises unreclassified — a real contract bug always pages, with every co-occurring
      # violation in one report; only when EVERY violation lands on a user-facing config does the
      # failure compose into one user-facing message.
      def _validate_inbound!
        failures = _collect_contract_failures
        failed_nodes = {}.compare_by_identity
        failures.each { |failure| failed_nodes[failure.path.node] = true if failure.path }

        # Causal suppression, post-hoc with COMPLETE failure knowledge (declaration order can't hide an
        # ancestor that failed after a descendant validated): a nil/invalid ancestor strands every
        # descendant (PRO-2857), so a stranded check's noise is attributed to the ancestor — it must
        # never page over a user-facing ancestor's message, nor pad a dev-facing report. A failed
        # top-level config marks its root node, so its whole subtree suppresses through the same rule.
        failures.reject! { |failure| failure.path && _suppressed_by_failed_ancestor?(failure.path, failed_nodes) }
        mismatches = _model_consistency_mismatches(failed_nodes)
        base_extras = mismatches.map(&:message) + _undeclared_input_messages

        return if failures.empty? && base_extras.empty?

        # Tool-invocation opt-in: treat the WHOLE inbound contract as user-facing for this call —
        # compose every violation (including model-consistency mismatches and unknown-input messages)
        # into one non-reported failure. No new classification; the existing user_facing settling,
        # applied contract-wide. EXCEPT when any ambient-rooted violation is present: ambient context is
        # trusted/adapter-supplied, not model input (the DSL already rejects `user_facing:` on ambient
        # subfields), so an ambient violation must stay dev-facing and report. Per the dominance doctrine,
        # one such violation makes the WHOLE set settle dev-facing via the path below (an ambient config's
        # `user_facing` is false, so `_failure_fully_user_facing?` already excludes it).
        raise _composed_user_facing_error(failures, base_extras) if _user_facing_input_errors? && !_any_ambient_violation?(failures, mismatches)

        raise InboundValidationError, _aggregate_errors(failures, base_extras) unless base_extras.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }

        # Resolve the user-facing message — invoking any Symbol/Proc handler — only now, once we know
        # this is the exception we actually raise (the dominance check above didn't pre-empt it), so a
        # discarded reclassification never fires an expensive/side-effecting handler for nothing.
        raise _composed_user_facing_error(failures)
      end

      ContractFailure = Data.define(:config, :path, :errors, :stranded_at)

      # A model-consistency mismatch (record vs. `<field>_id`), carrying its :base message plus whether
      # the failing config is ambient-rooted — so the tool-invocation gate can keep an ambient mismatch
      # dev-facing (see `_any_ambient_violation?`) without re-running the side-effecting resolution.
      ConsistencyMismatch = Data.define(:message, :ambient)

      # Whether any unsuppressed inbound violation roots at ambient context (trusted/adapter-supplied,
      # never model input). Used only by the tool-invocation gate to refuse the contract-wide user-facing
      # compose when an ambient violation is present, so the dev-facing settle path reports it instead.
      def _any_ambient_violation?(failures, mismatches)
        failures.any? { |failure| _ambient_config?(failure.config) } || mismatches.any?(&:ambient)
      end

      # A config is ambient-rooted when it's a subfield whose `on:` chain roots at :ambient_context.
      # Reuses the canonical class-level predicate; a top-level field (`on: nil`) is never ambient.
      def _ambient_config?(config)
        config.subfield? && @action_class.send(:_on_roots_at_ambient?, config.on)
      end

      # Every inbound config's errors — top-level fields and subfields through the one collector —
      # gathered in declaration order with no early exit: settling needs the complete set (both to
      # aggregate the report and to suppress stranded descendants accurately). A top-level field
      # validates against the inbound facade (which resolves model records and reads by wire key); a
      # subfield against its canonically-resolved parent, with its reader supplied for model resolution.
      def _collect_contract_failures
        coerce_input_types = _coerce_input_types?

        _inbound_configs.filter_map do |config|
          errors = Axn::Validation::Fields.collect_errors(
            field: config.field,
            validations: coerce_input_types ? _with_effective_coerce(config.validations) : config.validations,
            source: config.subfield? ? _resolved_parent_value(config) : @action.internal_context,
            action: @action,
            reader: config.subfield? ? config.reader_as : nil,
            config: config.subfield? ? config : nil,
          )
          next if errors.empty?

          path = _resolved_path_for(config)
          ContractFailure.new(config:, path:, errors:, stranded_at: path && _stranded_ancestor_path(path, config))
        end
      end

      # The dotted wire path of the first nil INTERMEDIATE ancestor along a failing subfield's chain
      # (nil when the chain is intact, or when the nil is the top-level root itself — a nil root is
      # self-evident in the report: its own presence error co-reports, or its absence is the classic
      # PRO-2857 semantics). Purely diagnostic: names which nested hop stranded the failing check, so
      # a "Note can't be blank" three levels deep doesn't send the caller hunting.
      def _stranded_ancestor_path(path, config)
        root_config = @action_class.send(:internal_field_configs).find { |c| c.field == path.wire_path.first }
        value = root_config ? Axn::Core::ContractForSubfields.resolve_value(@action, root_config) : @context.provided_data[path.wire_path.first]
        return nil if value.nil?

        path.wire_path[1..-2].each_with_index do |seg, i|
          value = Core::FieldResolvers.resolve(type: :extract, field: seg.to_s, provided_data: value,
                                               permit_method_call: _segment_permits_method_call?(path, i + 1, config))
          return path.wire_path[0..i + 1].join(".") if value.nil?
        end
        nil
      rescue Axn::ContractViolation::UnextractableError
        # A malformed intermediate isn't a nil strand — its own validation reports it; no diagnostic.
        nil
      end

      # Whether reading the wire segment at `wire_index` (≥1) may dispatch a method: governed by the
      # config of the node that segment PRODUCES (its child — the deeper hop's parent, or the leaf for
      # the last segment). A declared child carries its OWN opt-in; an IMPLICIT intermediate honors the
      # resolving `config`'s method_call: (PRO-2926), so this diagnostic dispatches exactly the hops
      # runtime resolution does and never crashes on the gate error where runtime would have dispatched.
      def _segment_permits_method_call?(path, wire_index, config)
        child = wire_index < path.ancestors.size ? path.ancestors[wire_index].first : path.node
        _node_dispatches?(child) || (child.implicit? && config.method_call)
      end

      # Whether a tree node is produced by a method_call: subfield. Single source for "is this hop sharp?"
      def _node_dispatches?(node) = node.configs.any?(&:method_call)

      def _suppressed_by_failed_ancestor?(path, failed_nodes)
        path.ancestors.any? { |node, _seg| failed_nodes.key?(node) }
      end

      # The one dev-facing exception: every unsuppressed violation in a single errors object, in
      # declaration order (top-level fields then subfields), with model-consistency mismatches and
      # stranded-path diagnostics on :base.
      def _aggregate_errors(failures, mismatches)
        errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
        failures.each do |failure|
          failure.errors.each { |err| errors.import(err) }
        end
        mismatches.each { |msg| errors.add(:base, msg) }
        failures.filter_map(&:stranded_at).uniq.each do |strand|
          errors.add(:base, "'#{Axn::Reflection::PropertyNames.renderable_label(strand)}' is nil, so nested " \
                            "expectations beneath it cannot be satisfied")
        end
        errors
      end

      # The one exception raised when every classification unit is user-facing: all errors aggregated
      # (so dev-facing introspection still sees the full picture), with the composed message drawn per
      # unit — each failing config's own `user_facing:` and each shape-member's own tagged intent — one
      # uniform path for every depth. Parts are de-duplicated so a String/Symbol member override on an
      # Array shape surfaces once rather than repeating per failing element.
      # base_extras are :base-level message strings (model-consistency mismatches and, under
      # reject_undeclared_inputs, unknown-input messages) that compose into the user-facing message and
      # aggregate onto :base. Empty by default, so the per-field-declared path is unchanged.
      def _composed_user_facing_error(failures, base_extras = [])
        parts = failures.flat_map { |failure| _user_facing_parts(failure) } + base_extras
        InboundValidationError.new(_aggregate_errors(failures, base_extras),
                                   user_facing: true, user_facing_message: parts.uniq.to_sentence)
      end

      # A ContractFailure is a container of errors at two classification granularities: a shape-member
      # error (tagged by ShapeValidator) is its own structural, individually-classified unit; every
      # other error is the field's OWN error.
      def _own_errors(failure) = failure.errors.reject { |e| e.options[:axn_shape_member] }
      def _member_errors(failure) = failure.errors.select { |e| e.options[:axn_shape_member] }

      # A failure composes user-facing only when EVERY classification unit is: the field's own errors
      # honor the field's `user_facing:` (own empty ⇒ vacuously satisfied), and each shape-member error
      # honors the member's own tagged intent. A member error defaults dev-facing, so an un-opted member
      # forces the aggregate dev-facing.
      def _failure_fully_user_facing?(failure)
        (_own_errors(failure).empty? || failure.config.user_facing) &&
          _member_errors(failure).all? { |e| e.options[:axn_member_user_facing] }
      end

      # The user-facing message part(s) for one failure, per classification unit: the field's own errors
      # resolve through the field's `user_facing:`; each shape-member error resolves through its own
      # tagged intent, scoped to just that member's failure. Reached only when the failure is fully
      # user-facing.
      def _user_facing_parts(failure)
        parts = []
        own = _own_errors(failure)
        if own.any?
          parts.concat(_resolve_user_facing_override(failure.config.user_facing,
                                                     own: own.map(&:full_message),
                                                     scoped_error: InboundValidationError.new(_errors_containing(own))))
        end
        _member_errors(failure).each do |error|
          parts.concat(_resolve_user_facing_override(error.options[:axn_member_user_facing],
                                                     own: [error.full_message],
                                                     scoped_error: InboundValidationError.new(_errors_containing([error]))))
        end
        parts
      end

      # A fresh ActiveModel::Errors carrying just the given Error objects, so a Symbol/Proc user_facing
      # handler resolving against it sees exactly that classification unit's message (not the aggregate).
      def _errors_containing(error_list)
        errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
        error_list.each { |err| errors.import(err) }
        errors
      end

      # Resolve one config's `user_facing:` setting into its message part(s): `true` → the field's own
      # validation message(s); a String → verbatim; a Symbol/callable → its return, invoked with an
      # error **scoped to that field** (so a shared `->(e) { e.message }` sees only its own field, not
      # the aggregate). A String/Symbol/callable that resolves blank falls back to the field's own
      # validation message, so a user-facing failure never surfaces as the dev-facing generic message.
      def _resolve_user_facing_override(setting, own:, scoped_error:)
        override = case setting
                   when true then own
                   when String then setting
                   else Core::Flow::Handlers::Invoker.call(action: @action, handler: setting,
                                                           exception: scoped_error,
                                                           operation: "resolving user_facing: message")
                   end
        # `presence` first (blank-aware: a handler returning `false`/`nil`/"" means "no message"),
        # then coerce — otherwise `false.to_s` would surface the literal "false" instead of falling
        # back to the field's own validation message.
        Array(override).filter_map { |m| m.presence&.to_s }.presence || own
      end

      # Under reject_undeclared_inputs, every provided top-level wire key that is neither a declared
      # field/subfield wire root nor the reserved ambient parent becomes a normal inbound error. Top-level
      # only: keys nested inside a Hash field are not the top-level contract's concern.
      def _undeclared_input_messages
        return [] unless _reject_undeclared_inputs?

        (@context.provided_data.keys - _declared_top_level_keys).map { |key| "unknown input: #{key}" }
      end

      # The set of legitimate top-level wire keys: each inbound config's resolved-path root (top-level
      # fields fall back to their own field name), plus the reserved always-present ambient parent.
      # Ambient subfields live in a separate ambient-scoped tree (no `_resolved_path_for`), so their leaf
      # name is never a top-level input — only the reserved ambient parent exempts them.
      def _declared_top_level_keys
        roots = _inbound_configs.filter_map do |config|
          next if _ambient_config?(config)

          path = _resolved_path_for(config)
          path ? path.wire_path.first : config.field
        end
        (roots + _model_id_top_level_keys + [Core::AmbientContext::PARENT]).uniq
      end

      # Every top-level `model:` field derives a `<field>_id` reader (Contract._define_model_id_reader)
      # that the resolver consumes as its lookup token (FieldResolvers::Model#derive_value) whenever no
      # record is provided, so a caller may legitimately supply `<field>_id` at the top level even with
      # no explicit sibling declared. Exempt that implicit key from the undeclared-input gate. Same
      # `<field>_id` convention (any config carrying a `model:`, not just id-based finders — a custom
      # finder reads its token off the same key) Contract keys off for sensitive-alias filtering. Only
      # top-level configs contribute: a subfield model's id key is nested, not a top-level provided key.
      def _model_id_top_level_keys
        @action_class.send(:internal_field_configs).filter_map do |config|
          Internal::FieldConfig.model_id_key(config.field) if config.validations[:model]
        end
      end

      # For id-based (`:find`) `model:` fields, reject contradictory input: a record AND a `<field>_id`
      # that disagree. The RECORD is always extracted raw (never a model lookup): a present record is
      # authoritative, so a defaulted sibling id must not override it into a fabricated conflict — the id
      # `default:` participates only via resolve_model_via_id (which fires only when the record is
      # absent). The `<field>_id` is compared against the CALLER-SUPPLIED token with the declared field's
      # own coerce:/preprocess: applied (never its default — see _consistency_id_for) at BOTH depths, so the
      # check agrees with what the reader and the finder path see; a default-only id (the caller supplied
      # nothing) resolves to nil here and never fabricates a conflict. Skipped for
      # custom finders, where `<field>_id` holds a finder-specific token rather than a primary key and a
      # record-vs-id comparison would be meaningless. Mismatches are structurally dev-facing, aggregated
      # into the settled exception's errors on :base (base messages render verbatim — each mismatch
      # carries its own field prefix). Subfield checks are causally suppressed like subfield validation: a
      # failed ancestor means this chain's data is already known-bad, so a consistency mismatch under it
      # is stranding noise.
      def _model_consistency_mismatches(failed_nodes)
        mismatches = []

        @action_class.send(:internal_field_configs).each do |config|
          next unless _id_based_model?(config)
          next if _model_gate_closed?(config) { @action.internal_context }

          # Reuse the per-config raw memo (present_record read the same key during resolution), so the
          # directly-provided record — and its `method_call:` dispatch — is read at most once (PRO-2910).
          record = Axn::Core::ContractForSubfields._memoized_raw_extract(@action, config, @context.provided_data)
          raw_id = _consistency_id_for(config)
          msg = _record_id_mismatch(field: config.field, record:, raw_id:)
          mismatches << ConsistencyMismatch.new(message: msg, ambient: false) if msg
        end

        @action_class.send(:subfield_configs).each do |config|
          next unless _id_based_model?(config)
          next if (path = _resolved_path_for(config)) && _suppressed_by_failed_ancestor?(path, failed_nodes)
          next if _model_gate_closed?(config) { _resolved_parent_value(config) }

          source = _resolved_parent_value(config)
          record = Axn::Core::ContractForSubfields._memoized_raw_extract(@action, config, source)
          raw_id = _consistency_id_for(config)
          msg = _record_id_mismatch(field: config.field, record:, raw_id:)
          mismatches << ConsistencyMismatch.new(message: msg, ambient: _ambient_config?(config)) if msg
        end

        mismatches
      end

      # A config whose MODEL validator is gated OFF for this call: ActiveModel has already waived it, so
      # the model-consistency check (which lives outside AM) must waive too — otherwise a gated-off model
      # field would still raise on a record/id conflict, the one check that survives a closed gate. Both
      # gate tiers are honored: the declaration-level shared if:/unless: AND the `model:` entry's OWN
      # nested if:/unless: (`model: { ..., if: }`), with AM's real tier precedence applied by the probe
      # (see Fields.validator_gate_open?). Key-presence on either tier is checked first, and the `source`
      # is yielded lazily, so an ungated config constructs nothing and resolves nothing — zero cost off
      # the gated path.
      def _model_gate_closed?(config)
        gate_keys = Internal::FieldConfig::CONDITIONAL_GATE_KEYS
        model = config.validations[:model]
        has_shared_gate = gate_keys.any? { |key| config.validations.key?(key) }
        has_nested_gate = model.is_a?(Hash) && gate_keys.any? { |key| model.key?(key) }
        return false unless has_shared_gate || has_nested_gate

        # The gate oracle asks ActiveModel itself (see Fields.validator_gate_open?): the action is
        # threaded, plus the subfield reader/config, so a Symbol/Proc gate resolves against the same
        # `self` and action delegation the real validators see. `source` is yielded only past the
        # key-presence guard, so an ungated config resolves nothing — zero cost off the gated path.
        !Axn::Validation::Fields.validator_gate_open?(
          validations: config.validations,
          entry_options: model,
          action: @action,
          source: yield,
          reader: config.subfield? ? config.reader_as : nil,
          config: config.subfield? ? config : nil,
        )
      end

      def _id_based_model?(config)
        model = config.validations[:model]
        model.is_a?(Hash) && model[:finder] == :find
      end

      # The <field>_id to check model consistency against, at EITHER depth (PRO-2910): nil unless the
      # caller actually supplied the id (a default-only id must not fabricate a conflict with a present
      # record — the record is authoritative), and otherwise the caller-supplied token with the declared
      # `<field>_id`'s coerce:/preprocess:/default: applied via its own reader value (resolve_value), so the
      # check compares exactly what the `<field>_id` reader, its validation, and the finder path
      # (resolve_model_via_id) all see. The `raw`-nil guard enforces present-record authority: a
      # caller-OMITTED id is exempted before any resolution, so its default never fabricates a conflict; a
      # caller-SUPPLIED id is compared as its own resolved value — normally its transform, or that route's
      # default when a present value's preprocess maps it to nil (exactly what the reader returns there).
      # Reusing the CACHED reader value also guarantees a stateful/side-effecting preprocess runs at most once
      # per call. A `<field>_id` with no declared field config carries no transform, so the raw token is used.
      def _consistency_id_for(config)
        sibling_configs = Axn::Core::ContractForSubfields.sibling_id_configs(@action, config)

        # No declared `<field>_id`: the caller's raw token carries no transform, read with the model field's own
        # `method_call:`. The `raw`-nil guard enforces present-record authority (an omitted id fabricates no
        # conflict). The raw source differs by depth: a top-level id off provided_data, a subfield id off the
        # resolved parent (the model leaf's own wire parent).
        if sibling_configs.empty?
          id_key = Internal::FieldConfig.model_id_key(config.field)
          source = config.subfield? ? _resolved_parent_value(config) : @context.provided_data
          return Core::FieldResolvers.extract_or_nil(field: id_key, provided_data: source, permit_method_call: config.method_call)
        end

        # Present-record authority: exempt a caller-OMITTED id (no declared route saw a raw token) before any
        # resolution, so a default-only id never fabricates a conflict with a present record. Probe presence via
        # the SAME memoized raw each route's reader consumes, so a `method_call:` id reader dispatches at most
        # once across the finder and consistency paths (PRO-2910).
        supplied = sibling_configs.any? do |sc|
          !Axn::Core::ContractForSubfields._memoized_raw_extract(@action, sc, Axn::Core::ContractForSubfields.resolve_parent(@action, sc)).nil?
        end
        return nil unless supplied

        # Compare against exactly the id the finder path would look up: the SAME declared `<field>_id` token
        # (ContractForSubfields._declared_id_token — depth-agnostic, ambient-aware, own-`on:`-route authoritative,
        # absent-id-only fall-through to a credited default route). A declared id that resolves to nil (a present
        # value its preprocess maps to nil, no own default) yields nil — no conflict — matching the reader and
        # the record lookup.
        Axn::Core::ContractForSubfields._declared_id_token(@action, sibling_configs)
      end

      # The comparison core, source-agnostic: a provided record whose id disagrees with a provided
      # `<field>_id` is a contradiction. A nil/blank id, an absent record, or a record without `.id` is
      # no conflict. Callers supply the record and the (resolved) id from the appropriate source: at both
      # depths the caller-supplied token with its declared transform applied, never a default — see
      # _consistency_id_for.
      def _record_id_mismatch(field:, record:, raw_id:)
        return nil if record.nil? || raw_id.nil? || raw_id.to_s.strip.empty?
        return nil unless record.respond_to?(:id)
        return nil if record.id.to_s == raw_id.to_s

        "#{field}: provided record (id=#{record.id.inspect}) conflicts with #{field}_id=#{raw_id.inspect} — pass one, or matching values"
      end

      def apply_defaults!(direction)
        raise ArgumentError, "Invalid direction: #{direction} (outbound-only)" unless direction == :outbound

        @action_class.send(:external_field_configs).each do |config|
          field = config.field
          # Copy an unexposed inbound value forward before considering the default, so a provided value
          # wins over a declared default. A field that is both `expects` and `exposes` is read through
          # internal_context, so the RESOLVED inbound value (coerce/preprocess/default applied on the
          # read path) is forwarded. A pure-`exposes` field has no inbound reader, but the caller may
          # still have supplied its wire key directly, so it copies the raw provided_data value.
          unless @context.exposed_data.key?(field)
            if @action_class.send(:internal_field_configs).any? { |c| c.field == field }
              @context.exposed_data[field] = @action.internal_context.public_send(field)
            elsif @context.provided_data.key?(field)
              @context.exposed_data[field] = @context.provided_data[field]
            end
          end

          next if config.default.nil?
          next if @context.exposed_data.key?(field) && !@context.exposed_data[field].nil?

          @context.exposed_data[field] = _resolve_default(config)
        end
      end

      def _resolve_default(config)
        Internal::FieldConfig.resolve_default(@action, config)
      end

      # on_success is defined to run only once the *enclosing* transaction durably commits
      # (immediately when none is open), and to be skipped if it rolls back.
      # ActiveRecord.after_all_transactions_commit (AR 7.2+) yields immediately with no open
      # transaction, otherwise registers an after_commit hook on the outermost transaction.
      # Guarded so non-Rails usage (no ActiveRecord) and pre-7.2 ActiveRecord (no
      # after_all_transactions_commit) both dispatch inline as before.
      def trigger_on_success
        dispatch = -> { @action_class._dispatch_callbacks(:success, action: @action, exception: nil) }

        if defined?(ActiveRecord) && ActiveRecord.respond_to?(:after_all_transactions_commit)
          ActiveRecord.after_all_transactions_commit(&dispatch)
        else
          dispatch.call
        end
      end

      # =========================================================================
      # HOOKS (Inside zone)
      # =========================================================================

      def with_hooks
        respecting_early_completion do
          run_around_hooks do
            respecting_early_completion do
              run_before_hooks
              yield
              run_after_hooks
            end
          end
        end
      end

      def run_around_hooks(&block)
        @action_class.around_hooks.reverse.inject(block) do |chain, hook|
          proc { run_hook(hook, chain) }
        end.call
      end

      def run_before_hooks
        run_hooks(@action_class.before_hooks)
      end

      def run_after_hooks
        run_hooks(@action_class.after_hooks.reverse)
      end

      def run_hooks(hooks)
        hooks.each { |hook| run_hook(hook) }
      end

      def run_hook(hook, *)
        hook.is_a?(Symbol) ? @action.send(hook, *) : @action.instance_exec(*, &hook)
      end

      def respecting_early_completion
        yield
      rescue Internal::EarlyCompletion => e
        @context.__record_early_completion(e.message, standalone: e.standalone)
        raise e
      end

      # =========================================================================
      # RESOLVED-PATH HELPERS
      # =========================================================================
      # Inbound validation is driven by each config's ResolvedPath from the per-class cached
      # SubfieldTree: the tree already translated `on:` reader aliases and dotted segments into the
      # full provided_data wire path once, at build. A top-level field is the depth-0 case
      # (wire_path == [field], no ancestors), so one collector covers both stores.

      # Both stores in declaration order, top-level first — the order inbound validation collects in.
      def _inbound_configs
        @action_class.send(:internal_field_configs) + @action_class.send(:subfield_configs)
      end

      def _resolved_path_for(config)
        @action_class._resolved_subfields.index[config]
      end

      # Drop the per-instance caches an early pre-pipeline read (a hook/preprocess touching a reader
      # before inbound validation runs) may have populated: ContractForSubfields' value-level cache
      # (@__resolve_value_cache) AND its raw-extract memo (@__raw_extract_memo) — both keyed by config in
      # resolve_value — plus each SUBFIELD reader's memoized value (@_memoized_reader_<reader_as>, see
      # Memoization.define_memoized_reader_method). Called at the top of with_contract — the settled inputs
      # are authoritative. Without this, a preprocess/default Proc (or a dynamic `sensitive:` predicate
      # resolved during before-logging) that reads a reader early caches a value against pre-pipeline state,
      # and validation (which public_sends the reader — see Validation::Fields) then sees stale input, so
      # invalid data passes. The raw memo is cleared alongside the value cache for the same reason: a stale
      # raw leaf would let validation re-run a parent preprocess/default yet still resolve the child from the
      # pre-pipeline wire value. Same accepted trade as the resolve_value clear: a Proc read early and re-read
      # post-clear runs twice.
      #
      # One ivar per reader-generating subfield config covers every flavor: the plain reader, and the
      # model RECORD reader (whose stale memo would otherwise pin a record resolved from the old id).
      # The model `<field>_id` reader is an unmemoized define_method (nothing to clear), and the boolean
      # `?` predicate is an alias of the primary reader (sharing its ivar), so neither needs its own clear.
      # Top-level reader memos live on the facade singleton, not the action instance, so they are not
      # cleared here: a top-level model record would re-run its finder — pre-existing behavior.
      def _clear_pre_pipeline_memos!
        @action.remove_instance_variable(:@__resolve_value_cache) if @action.instance_variable_defined?(:@__resolve_value_cache)
        @action.remove_instance_variable(:@__raw_extract_memo) if @action.instance_variable_defined?(:@__raw_extract_memo)

        @action_class.send(:subfield_configs).each do |config|
          ivar = :"@_memoized_reader_#{config.reader_as}"
          @action.remove_instance_variable(ivar) if @action.instance_variable_defined?(ivar)
        end
      end

      # The parent value a subfield validates against, resolved once per distinct `on:` target per
      # call — canonically, through the deepest reader-bearing ancestor (see
      # ContractForSubfields.resolve_parent), so both spellings of the same wire path share one
      # resolution. The parent itself is resolved on the read path (coerce/preprocess/default applied
      # without mutating provided_data), so this observes the same values the readers do. Keyed by
      # `method_call:` as well as the `on:` target: resolving an implicit method hop depends on the
      # resolving config's dispatch opt-in (PRO-2926), so two siblings under one `on:` that disagree on
      # `method_call:` must each resolve per their own flag — the non-opted-in one raising its own gate
      # regardless of order — rather than one reusing the other's dispatched (or refused) result.
      def _resolved_parent_value(config)
        memo = (@_resolved_parent_values ||= {})
        key = [config.on.to_s, config.method_call]
        memo.fetch(key) { memo[key] = Axn::Core::ContractForSubfields.resolve_parent(@action, config) }
      end

      # Per-call gate readers, anchored differently on purpose. coerce resolves through
      # CurrentCallOptions.coerce_input_types_for(@action) — the ACTION-anchored copy — because the
      # read-path value coercion in ContractForSubfields only has the action to read from, so both
      # readers must resolve off the same anchor to agree; it's tri-state, so a nil per-call value falls
      # back to the class/global setting (a normal call is unchanged) while the tool invoker forces
      # `true`. The other two gates are only ever consulted here in the executor, so they read the
      # executor's own `@__call_options` (nil for a normal call) directly.
      def _coerce_input_types? = Internal::CurrentCallOptions.coerce_input_types_for(@action)
      def _user_facing_input_errors? = @__call_options&.user_facing_input_errors || false
      def _reject_undeclared_inputs? = @__call_options&.reject_undeclared_inputs || false
    end
  end
end
