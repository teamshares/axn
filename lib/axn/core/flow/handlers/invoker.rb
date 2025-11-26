# frozen_string_literal: true

module Axn
  module Core
    module Flow
      module Handlers
        # Shared block evaluation with consistent arity handling and error piping
        module Invoker
          extend self

          def call(action:, handler:, exception: nil, operation: "executing handler")
            return call_symbol_handler(action:, symbol: handler, exception:) if symbol?(handler)
            return call_callable_handler(action:, callable: handler, exception:) if callable?(handler)

            literal_value(handler)
          rescue StandardError => e
            Axn::Internal::Logging.piping_error(operation, action:, exception: e)
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
            filtered_args, filtered_kwargs = Axn::Util::Callable.only_requested_params_for_exception(method, exception)
            action.send(symbol, *filtered_args, **filtered_kwargs)
          end

          def call_callable_handler(action:, callable:, exception: nil)
            filtered_args, filtered_kwargs = Axn::Util::Callable.only_requested_params_for_exception(callable, exception)
            action.instance_exec(*filtered_args, **filtered_kwargs, &callable)
          end

          def literal_value(value) = value
        end
      end
    end
  end
end
