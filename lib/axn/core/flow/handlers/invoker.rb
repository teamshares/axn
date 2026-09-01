# frozen_string_literal: true

require "English"
module Axn
  module Core
    module Flow
      module Handlers
        # Shared block evaluation with consistent arity handling and error piping.
        #
        # allow_flow_control: when true, done!/fail! (EarlyCompletion/Failure) propagate
        #   out of the handler — use for execution-phase blocks (preprocess, defaults, etc.)
        #   where the user legitimately controls action flow. When false (default), they are
        #   piped as errors — use for post-execution contexts (callbacks, messages, matchers)
        #   where the result is already finalized.
        module Invoker
          extend self

          # `on_swallow:` is what a handler's return value becomes when a raise is swallowed below —
          # `nil` by default, which is indistinguishable from a handler that genuinely returned `nil`.
          # That's fine for most callers (a nil callback return, a nil message body), but a caller
          # that INVERTS the result (`SingleRuleMatcher`'s `unless:`) needs to tell "swallowed" apart
          # from "genuinely falsy": inverting a genuine `false` is correct (the exclusion doesn't
          # apply, so it's a match), but inverting "the rule blew up" must never turn a broken rule
          # into a match. This stays the ONE swallow policy — Invoker still decides what to catch and
          # when — a caller opting into a distinct sentinel changes nothing about that, only what it
          # reads back afterward.
          def call(action:, handler:, exception: nil, operation: "executing handler", allow_flow_control: false, on_swallow: nil)
            return call_symbol_handler(action:, symbol: handler, exception:) if symbol?(handler)
            return call_callable_handler(action:, callable: handler, exception:) if callable?(handler)

            literal_value(handler)
          rescue Axn::Internal::EarlyCompletion, Axn::Failure
            raise if allow_flow_control

            Axn::Extensions.best_effort(operation, action:) { raise $ERROR_INFO }
            on_swallow
          rescue StandardError => e
            Axn::Extensions.best_effort(operation, action:) { raise e }
            on_swallow
          rescue Exception => e # rubocop:disable Lint/RescueException
            # A handler that blows the stack (or hits an unfinished method) is a bug in the HANDLER, and
            # must not become the action's outcome. This matters most on the settle path: a callback
            # dispatched from the executor's rescue clause raises past the sibling `rescue Exception`
            # there, so without this the callback's exception would escape `.call` and replace the real
            # failure the callback was invoked to observe. Anything axn doesn't absorb (a signal, an
            # `exit`, a library's own control-flow signal) still propagates untouched.
            raise unless Axn::Extensions.swallowable?(e)

            Axn::Extensions.best_effort(operation, action:) { raise e }
            on_swallow
          end

          # Public so the contract DSL can validate a declared handler against the same notion of
          # "invokable" used here at call time — what `expects ..., user_facing:` accepts is exactly
          # what this invoker will actually call, with no second, divergent predicate. Requires both
          # traits the invoker actually uses: `to_proc` (it runs the handler as `instance_exec(&...)`)
          # and `arity` (it arity-filters the args). An object answering one but not the other would
          # pass an arity-only check yet raise at call time — Procs/lambdas/Methods answer both.
          def callable?(value) = value.respond_to?(:to_proc) && value.respond_to?(:arity)

          private

          def symbol?(value) = value.is_a?(Symbol)

          def call_symbol_handler(action:, symbol:, exception: nil)
            unless action.respond_to?(symbol, true)
              Axn::Internal::ActionState.log(action,
                                             "Ignoring apparently-invalid symbol #{symbol.inspect} -- action does not respond to method",
                                             level: :warn)
              return nil
            end

            method = action.method(symbol)
            filtered_args, filtered_kwargs = Axn::Internal::Callable.only_requested_params_for_exception(method, exception)
            action.send(symbol, *filtered_args, **filtered_kwargs)
          end

          def call_callable_handler(action:, callable:, exception: nil)
            filtered_args, filtered_kwargs = Axn::Internal::Callable.only_requested_params_for_exception(callable, exception)
            action.instance_exec(*filtered_args, **filtered_kwargs, &callable)
          end

          def literal_value(value) = value
        end
      end
    end
  end
end
