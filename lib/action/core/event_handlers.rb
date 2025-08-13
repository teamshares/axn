# frozen_string_literal: true

module Action
  module EventHandlers
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

        @matcher.matches?(exception:, action:)
      end

      def execute_if_matches(action:, exception:)
        return false unless matches?(exception:, action:)

        if @handler.respond_to?(:arity) && @handler.arity == 1
          action.instance_exec(exception, &@handler)
        else
          action.instance_exec(&@handler)
        end
        true
      rescue StandardError => e
        Axn::Util.piping_error("executing handler", action:, exception: e)
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

        @matcher.matches?(exception:, action:)
      end
    end

    class Matcher
      def initialize(matcher)
        @matcher = matcher
      end

      def matches?(exception:, action:)
        if matcher.respond_to?(:call)
          if matcher.arity == 1
            !!action.instance_exec(exception, &matcher)
          else
            !!action.instance_exec(&matcher)
          end
        elsif matcher.is_a?(String) || matcher.is_a?(Symbol)
          klass = Object.const_get(matcher.to_s)
          klass && exception.is_a?(klass)
        elsif matcher < Exception
          exception.is_a?(matcher)
        else
          action.warn("Ignoring apparently-invalid matcher #{matcher.inspect} -- could not find way to apply it")
          false
        end
      rescue StandardError => e
        Axn::Util.piping_error("determining if handler applies to exception", action:, exception: e)
      end

      private attr_reader :matcher
    end
  end
end
