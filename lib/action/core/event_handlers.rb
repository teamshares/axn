# frozen_string_literal: true

module Action
  module EventHandlers
    class CustomErrorInterceptor
      def initialize(matcher:, message:)
        @matcher = Matcher.new(matcher)
        @message = message
      end

      delegate :matches?, to: :@matcher
      attr_reader :message
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
        Axn::Util.piping_error("executing handler", action:, exception: e)
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
