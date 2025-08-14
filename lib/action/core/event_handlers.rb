# frozen_string_literal: true

module Action
  module EventHandlers
    # Shared block evaluation with consistent arity handling and error piping
    module EvalAdapter
      module_function

      def call_block(action:, block:, exception: nil, operation: "executing handler")
        if block.is_a?(Symbol)
          unless action.respond_to?(block)
            action.warn("Ignoring apparently-invalid symbol #{block.inspect} -- action does not respond to method")
            return nil
          end

          method = action.method(block)
          if exception && (method.arity == 1 || method.arity < 0)
            action.public_send(block, exception)
          else
            action.public_send(block)
          end
        elsif block.respond_to?(:arity)
          if exception && block.arity == 1
            action.instance_exec(exception, &block)
          else
            action.instance_exec(&block)
          end
        else
          # Non-callable (e.g., String): return as-is
          block
        end
      rescue StandardError => e
        Axn::Util.piping_error(operation, action:, exception: e)
        nil
      end
    end

    # Small, immutable, copy-on-write registry keyed by event_type.
    # Stores arrays of entries (handlers/interceptors) in insertion order.
    class Registry
      def self.empty = new({})

      def initialize(index)
        # Freeze arrays and the index for immutability
        @index = index.transform_values { |arr| Array(arr).freeze }.freeze
      end

      def register(event_type:, entry:, prepend: true)
        key = event_type.to_sym
        existing = Array(@index[key])
        updated = prepend ? [entry] + existing : existing + [entry]
        self.class.new(@index.merge(key => updated.freeze))
      end

      def for(event_type)
        Array(@index[event_type.to_sym])
      end

      def empty?
        @index.empty?
      end

      protected

      attr_reader :index
    end

    class CallbackHandler
      def initialize(matcher:, handler:)
        @matcher = matcher.nil? ? nil : Matcher.new(matcher)
        @handler = handler
      end

      def matches?(exception:, action:)
        return true if @matcher.nil?

        @matcher.call(exception:, action:)
      end

      def execute_if_matches(action:, exception:)
        return false unless matches?(exception:, action:)

        EvalAdapter.call_block(action:, block: @handler, exception:, operation: "executing handler")
        true
      end
    end

    class MessageHandler
      def initialize(matcher:, message:, static: false)
        @matcher = Matcher.new(matcher)
        @message = message
        @static = !!static
      end

      attr_reader :message

      def static? = @static

      def matches?(exception:, action:)
        return true if static?

        @matcher.call(exception:, action:)
      end

      # Returns a string (truthy) when it applies and yields a non-blank message; otherwise nil
      def execute_if_matches(action:, exception:)
        return nil unless matches?(exception:, action:)

        value = if message.is_a?(Symbol) || message.respond_to?(:call)
                  EvalAdapter.call_block(action:, block: message, exception:, operation: "determining message callable")
                else
                  message
                end
        value.respond_to?(:presence) ? value.presence : value
      end
    end

    class Matcher
      def initialize(rule)
        @rule = rule
      end

      def call(exception:, action:)
        return apply_callable(action:, exception:) if callable?
        return apply_symbol(action:, exception:) if symbol?
        return apply_string(exception:) if string?
        return apply_exception_class(exception:) if exception_class?

        handle_invalid(action:)
      rescue StandardError => e
        Axn::Util.piping_error("determining if handler applies to exception", action:, exception: e)
      end

      private

      def callable? = @rule.respond_to?(:call)
      def symbol? = @rule.is_a?(Symbol)
      def string? = @rule.is_a?(String)
      def exception_class? = @rule.is_a?(Class) && @rule <= Exception

      def apply_callable(action:, exception:)
        if @rule.arity == 1
          !!action.instance_exec(exception, &@rule)
        else
          !!action.instance_exec(&@rule)
        end
      end

      def apply_symbol(action:, exception:)
        if action.respond_to?(@rule)
          method = action.method(@rule)
          if method_accepts_exception?(method)
            !!action.public_send(@rule, exception)
          else
            !!action.public_send(@rule)
          end
        else
          begin
            klass = Object.const_get(@rule.to_s)
            klass && exception.is_a?(klass)
          rescue NameError
            action.warn("Ignoring apparently-invalid matcher #{@rule.inspect} -- neither action method nor constant found")
            false
          end
        end
      end

      def apply_string(exception:)
        klass = Object.const_get(@rule.to_s)
        klass && exception.is_a?(klass)
      end

      def apply_exception_class(exception:)
        exception.is_a?(@rule)
      end

      def handle_invalid(action:)
        action.warn("Ignoring apparently-invalid matcher #{@rule.inspect} -- could not find way to apply it")
        false
      end

      def method_accepts_exception?(method) = method.arity == 1 || method.arity < 0
    end
  end
end
