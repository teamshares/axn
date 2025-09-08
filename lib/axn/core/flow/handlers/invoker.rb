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

          # Shared introspection helpers
          def accepts_exception_keyword?(callable_or_method)
            return false unless callable_or_method.respond_to?(:parameters)

            params = callable_or_method.parameters
            params.any? { |type, name| %i[keyreq key].include?(type) && name == :exception } ||
              params.any? { |type, _| type == :keyrest }
          end

          def accepts_positional_exception?(callable_or_method)
            return false unless callable_or_method.respond_to?(:arity)

            arity = callable_or_method.arity
            arity == 1 || arity.negative?
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
            if exception && accepts_exception_keyword?(method)
              action.send(symbol, exception:)
            elsif exception && accepts_positional_exception?(method)
              action.send(symbol, exception)
            else
              action.send(symbol)
            end
          end

          def call_callable_handler(action:, callable:, exception: nil)
            if exception && accepts_exception_keyword?(callable)
              action.instance_exec(exception:, &callable)
            elsif exception && accepts_positional_exception?(callable)
              action.instance_exec(exception, &callable)
            else
              action.instance_exec(&callable)
            end
          end

          def literal_value(value) = value
        end
      end
    end
  end
end
