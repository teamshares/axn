# frozen_string_literal: true

module Action
  module EventHandlers
    class CustomErrorInterceptor
      def initialize(matcher:, message:, should_report_error:)
        @matcher = Matcher.new(matcher)
        @message = message
        @should_report_error = should_report_error
      end

      delegate :matches?, to: :@matcher
      attr_reader :message, :should_report_error
    end

    class ConditionalHandler
      def initialize(matcher:, handler:)
        @matcher = Matcher.new(matcher)
        @handler = handler
      end

      delegate :matches?, to: :@matcher

      def execute_if_matches(action:, exception:)
        return false unless matches?(exception:, action:)

        action.instance_exec(exception, &@handler)
        true
      rescue StandardError => e
        action.warn("Ignoring #{e.class.name} in when evaluating #{self.class.name} handler: #{e.message}")
        nil
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
        action.warn("Ignoring #{e.class.name} raised while determining matcher: #{e.message}")
        false
      end

      private attr_reader :matcher
    end
  end
end
