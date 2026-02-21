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

          def call(action:, handler:, exception: nil, operation: "executing handler", allow_flow_control: false)
            return call_symbol_handler(action:, symbol: handler, exception:) if symbol?(handler)
            return call_callable_handler(action:, callable: handler, exception:) if callable?(handler)

            literal_value(handler)
          rescue Axn::Internal::EarlyCompletion, Axn::Failure
            raise if allow_flow_control

            Axn::Internal::PipingError.swallow(operation, action:, exception: $ERROR_INFO)
          rescue StandardError => e
            Axn::Internal::PipingError.swallow(operation, action:, exception: e)
          end

          private

          def symbol?(value) = value.is_a?(Symbol)

          def callable?(value) = value.respond_to?(:arity)

          def call_symbol_handler(action:, symbol:, exception: nil)
            unless action.respond_to?(symbol, true)
              action.warn("Ignoring apparently-invalid symbol #{symbol.inspect} -- action does not respond to method")
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
