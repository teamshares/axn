# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"
require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/rendering"
require "axn/internal/text"

module Axn
  module Core
    module Flow
      module Handlers
        module Resolvers
          # Internal: resolves messages with different strategies
          class MessageResolver < BaseResolver
            DEFAULT_ERROR = "Something went wrong"
            DEFAULT_SUCCESS = "Action completed successfully"
            DEFAULT_JOIN = ": "

            def resolve_message
              descriptor, reason = matched_reason
              return base_message || fallback_message unless descriptor

              descriptor.standalone? ? reason : with_base(reason)
            end

            # The winning reason as [descriptor, body], or nil if no conditional/dynamic (or explicitly
            # `standalone: false`) entry matches. Unconditional standalone entries are headlines, excluded
            # here and surfaced via base_message. filter_map captures each body once (body_for invokes the
            # handler block), so the winning entry's message block runs a single time. Memoized — a
            # resolver is single-use — so an external caller (Result#_resolve_error, deciding whether a
            # parent override should beat a bubbled child message) and resolve_message share one pass.
            #
            # Plain truthiness: an entry that supplied no body is already nil, decided undispatched in
            # `body_for`, which is the one place that question is asked about a handler's own return value.
            def matched_reason
              return @matched_reason if defined?(@matched_reason)

              @matched_reason = matching_entries.lazy.filter_map do |d|
                next unless reason?(d)

                body = body_for(d)
                [d, body] if body
              end.first
            end

            def resolve_default_message = base_message || fallback_message

            # Combine an externally-supplied reason (e.g. a fail!/done! message) with the base.
            #
            # Truthiness rather than `present?`, on the same terms as `matched_reason` above: a base that
            # resolved to nothing is already nil, and what a resolved base HOLDS is the handler's own return
            # value — asking that object whether it is blank runs the caller's code from inside the path
            # settling the failure.
            def with_base(reason)
              return reason unless base_message

              combine(base_message, reason)
            end

            def base_message = resolved_base&.last

            private

            # Unconditional, standalone entries with a handler — the headline candidates. The handler
            # kind (literal/block/symbol) is irrelevant; only conditionality + standalone: decide the
            # role. Applies to both :error and :success events. Memoized: a resolver is single-use, and
            # this is consulted once per matching entry (via reason?/base_descriptor) plus once by
            # resolved_base.
            def base_candidates = @base_candidates ||= candidate_entries.select { |d| d.static? && d.standalone? && d.handler }

            # The headline that actually resolves, as [descriptor, body]. Headlines form a fallback chain
            # (most-recent first — see Registry): a headline whose block raises or returns blank falls
            # back to an earlier one. The body AND its join both come from this descriptor, so a
            # blank/raising newer headline can't impose its join on an earlier headline's text.
            def resolved_base
              return @resolved_base if defined?(@resolved_base)

              @resolved_base = base_candidates.lazy.filter_map { |d| (body = body_for(d)) && [d, body] }.first
            end

            # Whether a base is *declared* (gates whether reasons are attached) — independent of whether
            # its body resolves to something present (the most-recently declared headline).
            def base_descriptor = base_candidates.first

            # A "reason" is an entry eligible to be selected as the displayed message: a conditional
            # entry (if:/unless:) or one explicitly promoted with `standalone: false`. Unconditional
            # standalone entries are headlines (the base + any secondary headlines) — surfaced via
            # base_message, never selected here. When no base exists, every entry is conditional or
            # promoted, so all qualify.
            def reason?(descriptor)
              return true unless base_descriptor

              !descriptor.standalone? || !descriptor.static?
            end

            # The join comes from the headline whose body we're actually showing (resolved_base), NOT
            # the most-recent declared one. nil → default; an explicit "" String is honored verbatim.
            def join = resolved_base&.first&.join

            # Combine base and reason. A String join is the infix separator; a Proc join receives
            # (base, reason) and returns the combined string. DEFAULT_JOIN is used when unset.
            #
            # The caller's separator is RENDERED here, where it enters the message, on the same terms as the
            # two halves it sits between (see `joined`). It is the third foreign operand of one composition,
            # and rendering only the halves is worse than rendering none: a Latin-1 base and a Latin-1
            # separator join as they stand, while a UTF-8 half beside a Latin-1 separator raises
            # `Encoding::CompatibilityError` from the interpolation — the reporting failure replacing the
            # failure being reported. `Text.renderable` is the byte half alone, which is all a separator needs:
            # it is already known to be a String, so nothing is dispatched to read it.
            def combine(base, reason)
              j = join
              return apply_join_proc(j, base, reason) if j.respond_to?(:call)
              return joined(base, reason, Axn::Internal::Text.renderable(j)) if j.is_a?(String)

              joined(base, reason, DEFAULT_JOIN)
            end

            # The composed message, with each half rendered BEFORE it is interpolated.
            #
            # Each half is whatever a declared `error`/`success` handler returned or a caller handed `fail!`,
            # and interpolating it dispatches that object's `to_s` — from inside the path settling the failure,
            # one step above the callback dispatch, and again on every later `result.error`/`result.message`
            # read. So each is rendered behind a guard (`Rendering.value_rendering`), and a half that cannot
            # render is named by its CLASS — the fallback `Rendering.exception_message` and `Identity.describe`
            # both take when an object's own rendering will not answer. A raising `to_s` therefore costs that
            # fragment, not the settlement, the callbacks, or the call.
            #
            # The separator arrives already rendered — axn's own `DEFAULT_JOIN`, or the caller's `join:` put
            # through the byte renderer by `combine` — so all three operands of this composition are UTF-8
            # Strings axn owns. That is the whole requirement: rendering a SUBSET of them would convert a join
            # that worked (a Latin-1 base beside a Latin-1 separator) into an `Encoding::CompatibilityError`.
            def joined(base, reason, separator) = "#{fragment(base)}#{separator}#{fragment(reason)}"

            def fragment(value)
              Axn::Internal::Rendering.value_rendering(value) || Axn::Internal::Rendering.class_name(value)
            end

            # A join Proc runs on the presentation path, which must never raise. A Proc that raises,
            # mismatches arity, or returns a non-String falls back to the default join (and warns) —
            # mirroring how a base-header block that raises falls back down the headline chain.
            def apply_join_proc(proc, base, reason)
              unless join_accepts_base_and_reason?(proc)
                reported_arity = proc.is_a?(Proc) || proc.is_a?(Method) ? proc.arity : proc.method(:call).arity
                action.warn("join: callable cannot accept (base, reason) (arity #{reported_arity}) — using default join")
                return joined(base, reason, DEFAULT_JOIN)
              end

              result = proc.call(base, reason)
              # `Module#===` rather than `result.is_a?(String)`: the joiner's return value is caller-supplied,
              # and this test decides whether it is RETURNED as the message. A value that claimed to be a
              # String would be handed on and interpolated by whoever reads `result.error`, dispatching its
              # `to_s` outside this method's rescue. Naming its class goes through the same funnel as the
              # rescue below, for the same reason: `result.class` is the value's own override.
              return result if Axn::Internal::Identity.kind?(result, String) && result.present?

              detail = if Axn::Internal::Identity.kind?(result, String)
                         "a blank String"
                       else
                         Axn::Internal::Rendering.class_name(result)
                       end
              action.warn("join: callable returned #{detail} (expected a non-blank String) — using default join")
              joined(base, reason, DEFAULT_JOIN)
            # Whatever the joiner raised, the fallback applies — this path "must never raise" (above), and
            # it is reached from `result.error` DURING settlement. A class slipping past here would abort
            # `_settle_exception!` after the exception was recorded but before on_error/on_failure/
            # on_exception and the global report, and would raise again on every later `result.error`
            # read. Only what axn absorbs is caught, so a signal still propagates.
            rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
              action.warn("join: Proc raised #{Axn::Internal::Rendering.class_name(e)}: " \
                          "#{Axn::Internal::Rendering.exception_message(e)} — using default join")
              joined(base, reason, DEFAULT_JOIN)
            end

            # A joiner accepts (base, reason) iff it takes exactly 2 positional args, or is variadic
            # with <= 2 required args. Matches how a lambda would accept the call (non-lambda Procs
            # don't enforce arity themselves, so we check explicitly).
            # Procs/Methods answer #arity directly. Any other callable (a plain object with #call)
            # reports its arity via #call.arity — we must NOT use .method(:call).arity on a Proc
            # because Proc#call is variadic (arity -1) and would defeat the check.
            def join_accepts_base_and_reason?(callable)
              arity = callable.is_a?(Proc) || callable.is_a?(Method) ? callable.arity : callable.method(:call).arity
              arity == 2 || (arity.negative? && (-arity - 1) <= 2)
            end

            # This descriptor's message body, or nil when it supplied none — the ONE place that question is
            # asked, so every reader downstream (`matched_reason`, `resolved_base`, `with_base`,
            # `Result#_error_from_declared_source?`) takes the nil as the answer and asks nothing further.
            #
            # A handler's return value is the CALLER's object, and this runs while a failure is being settled
            # and again on every later `result.error`/`result.message` read, so `presence` here dispatched that
            # object's `blank?` from inside axn's own reporting: an override that raises replaces the failure
            # being reported with its own exception, and outside StandardError it escapes the rescue meant to
            # settle it. `error -> { obj }` with an object that could not answer aborted settlement — the
            # warning named a reporting failure and the outcome read `exception` — and raised again on every
            # `result.error` read afterwards. Decided instead from the value's class and its own bytes, the
            # same undispatched answer `Axn::Failure#supplied_reason` gives a `fail!` reason.
            def body_for(descriptor)
              return nil unless descriptor

              if descriptor.handler
                supplied_body(Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:))
              elsif exception
                supplied_body(Axn::Internal::Rendering.exception_message(exception))
              end
            end

            def supplied_body(body) = Axn::Internal::NativeMethods.absent_value?(body) ? nil : body

            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
