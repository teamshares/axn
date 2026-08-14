# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"
require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/rendering"

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
            # The separator is handed on AS IT CAME. Which separator this is depends on a branch here and on
            # three more inside `apply_join_proc`, so rendering it per-branch would put the composition's
            # correctness back on enumerating six call sites; `joined` normalizes it instead (see there).
            #
            # Neither branch asks the `join:` value anything, and the ORDER is what removes the need for a
            # callable probe at all. `join:` is the declaring author's object rather than an arbitrary
            # caller's, but this runs on the settlement path, so a `respond_to?` here escaped `.call`
            # entirely rather than costing the separator.
            #
            # `MessageDescriptor.build` has already rejected a join that is neither a String nor callable, so
            # what arrives here has answered both questions once. That is evidence about the FIRST call and
            # nothing more — the same bound that made a non-idempotent `Exception#exception` reachable after
            # the object had already been raised once — which is why the answer is taken from the hierarchy
            # here rather than from the declaration having passed.
            #
            # String first, so an explicit `""` is honored verbatim before absence is considered; then
            # absence (an unset `nil` join) through the gem's single undispatched answer to "was anything
            # supplied"; then everything else to `apply_join_proc`, which already carries the guard this path
            # needs. Nothing is left to fall through to a silent default.
            def combine(base, reason)
              j = join
              return joined(base, reason, j) if Axn::Internal::Identity.kind?(j, ::String)
              return joined(base, reason, DEFAULT_JOIN) if Axn::Internal::NativeMethods.absent_value?(j)

              apply_join_proc(j, base, reason)
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
            # ALL THREE operands go through the same `fragment`, here at the join, whatever each of them is and
            # wherever it came from.
            #
            # That is a requirement rather than a convenience, and the reason is that an
            # `Encoding::CompatibilityError` needs two INCOMPATIBLE operands: a wholly raw join composes (a
            # Latin-1 base beside a Latin-1 separator) and a wholly rendered one composes, while rendering a
            # SUBSET is what raises. So the rendering has to live where the join is, because there is no way to
            # be sure every place that SUPPLIES an operand rendered it — six call sites decide the separator
            # alone (three branches of `combine`, three of `apply_join_proc`), and correctness that depends on
            # all of them agreeing is correctness that a seventh silently breaks. One normalization point
            # cannot be partially applied.
            def joined(base, reason, separator) = "#{fragment(base)}#{fragment(separator)}#{fragment(reason)}"

            def fragment(value)
              Axn::Internal::Rendering.value_rendering(value) || Axn::Internal::Rendering.class_name(value)
            end

            # A join Proc runs on the presentation path, which must never raise. A Proc that raises,
            # mismatches arity, or returns a non-String falls back to the default join (and warns) —
            # mirroring how a base-header block that raises falls back down the headline chain.
            #
            # The Proc receives the halves ALREADY RENDERED — the same `fragment` every other branch of the
            # join composes through — so what it is handed is a UTF-8 String this class owns rather than
            # whatever a declared `error` handler returned or a caller passed `fail!`. Two things follow.
            # The Proc's own interpolation can no longer dispatch a hostile `to_s`, which is the one dispatch
            # on this path axn could not otherwise contain: it happens inside the caller's block, and outside
            # StandardError it escapes the rescue below. And `reason.upcase` — the recasing the interface is
            # documented for — works on the object it is documented to work on.
            #
            # Rendering here rather than in `combine` keeps it at the point the Proc is actually handed the
            # operands; the DEFAULT_JOIN fallbacks below pass the raw halves to `joined`, which renders them
            # itself, and rendering is idempotent either way.
            def apply_join_proc(proc, base, reason)
              unless join_accepts_base_and_reason?(proc)
                _warn("join: callable cannot accept (base, reason) (arity #{callable_arity(proc)}) — using default join")
                return joined(base, reason, DEFAULT_JOIN)
              end

              result = proc.call(fragment(base), fragment(reason))
              # `Module#===` rather than `result.is_a?(String)`: the joiner's return value is caller-supplied,
              # and this test decides whether it is RETURNED as the message. A value that claimed to be a
              # String would be handed on and interpolated by whoever reads `result.error`, dispatching its
              # `to_s` outside this method's rescue. Naming its class goes through the same funnel as the
              # rescue below, for the same reason: `result.class` is the value's own override.
              # Blankness comes from `absent_value?` rather than `present?`, on the same terms as the
              # `kind?` beside it: `present?` is an ActiveSupport method on Object, so the String SUBCLASS
              # this line has just admitted can override it — and a value answering "present" here and
              # "blank" to a later reader is returned AS the message and interpolated by whoever reads
              # `result.error`. Reading its own bytes is the one undispatched answer the gem gives that
              # question.
              return result if Axn::Internal::Identity.kind?(result, String) && !Axn::Internal::NativeMethods.absent_value?(result)

              detail = if Axn::Internal::Identity.kind?(result, String)
                         "a blank String"
                       else
                         Axn::Internal::Rendering.class_name(result)
                       end
              _warn("join: callable returned #{detail} (expected a non-blank String) — using default join")
              joined(base, reason, DEFAULT_JOIN)
            # Whatever the joiner raised, the fallback applies — this path "must never raise" (above), and
            # it is reached from `result.error` DURING settlement. A class slipping past here would abort
            # `_settle_exception!` after the exception was recorded but before on_error/on_failure/
            # on_exception and the global report, and would raise again on every later `result.error`
            # read. Only what axn absorbs is caught, so a signal still propagates.
            rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
              _warn("join: Proc raised #{Axn::Internal::Rendering.class_name(e)}: " \
                    "#{Axn::Internal::Rendering.exception_message(e)} — using default join")
              joined(base, reason, DEFAULT_JOIN)
            end

            # The three `join:` diagnostics share one emitter, so none of them can drift back onto a
            # dispatched `action.warn` — which the action's author is free to have taken for a field.
            def _warn(message) = Axn::Internal::ActionState.log(action, message, level: :warn)

            # A joiner accepts (base, reason) iff it takes exactly 2 positional args, or is variadic
            # with <= 2 required args. Matches how a lambda would accept the call (non-lambda Procs
            # don't enforce arity themselves, so we check explicitly).
            def join_accepts_base_and_reason?(callable)
              arity = callable_arity(callable)
              arity == 2 || (arity.negative? && (-arity - 1) <= 2)
            end

            # Procs/Methods answer #arity directly. Any other callable (a plain object with #call) reports its
            # arity via #call.arity — we must NOT use .method(:call).arity on a Proc because Proc#call is
            # variadic (arity -1) and would defeat the check. One reader, because the guard and the warning
            # that names why the guard failed have to agree on which arity they are talking about.
            #
            # Undispatched type tests, and the `.method(:call)`/`#arity` reads that follow are the caller's —
            # deliberately, since asking what a callable ACCEPTS has no undispatched form. They stay inside
            # `apply_join_proc`'s rescue, which is where a value with no `call` at all (`join: 123`) lands.
            def callable_arity(callable)
              own_arity = Axn::Internal::Identity.kind?(callable, ::Proc) || Axn::Internal::Identity.kind?(callable, ::Method)
              return callable.arity if own_arity

              callable.method(:call).arity
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
