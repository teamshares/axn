# frozen_string_literal: true

require_relative "event_handlers"

module Action
  module HandleExceptions
    def self.included(base)
      base.class_eval do
        class_attribute :_success_msg, :_error_msg
        class_attribute :_custom_error_interceptors, default: []
        class_attribute :_error_handlers, default: []
        class_attribute :_exception_handlers, default: []
        class_attribute :_failure_handlers, default: []

        include InstanceMethods
        extend ClassMethods

        def run
          run!
        rescue StandardError => e
          # on_error handlers run for both unhandled exceptions and fail!
          self.class._error_handlers.each do |handler|
            handler.execute_if_matches(exception: e, action: self)
          end

          # on_failure handlers run ONLY for fail!
          if e.is_a?(Action::Failure)
            @context.instance_variable_set("@error_from_user", e.message) if e.message.present?

            self.class._failure_handlers.each do |handler|
              handler.execute_if_matches(exception: e, action: self)
            end
          else
            # on_exception handlers run for ONLY for unhandled exceptions. AND NOTE: may be skipped if the exception is rescued via `rescues`.
            trigger_on_exception(e)

            @context.exception = e
          end

          @context.instance_variable_set("@failure", true)
        end

        def trigger_on_exception(exception)
          interceptor = self.class._error_interceptor_for(exception:, action: self)
          return if interceptor&.should_report_error == false

          # Call any handlers registered on *this specific action* class
          self.class._exception_handlers.each do |handler|
            handler.execute_if_matches(exception:, action: self)
          end

          # Call any global handlers
          Action.config.on_exception(exception,
                                     action: self,
                                     context: respond_to?(:context_for_logging) ? context_for_logging : @context.to_h)
        rescue StandardError => e
          # No action needed -- downstream #on_exception implementation should ideally log any internal failures, but
          # we don't want exception *handling* failures to cascade and overwrite the original exception.
          Axn::Util.piping_error("executing on_exception hooks", action: self, exception: e)
        end

        class << base
          def call!(context = {})
            result = call(context)
            return result if result.ok?

            raise result.exception || Action::Failure.new(result.error)
          end
        end
      end
    end

    module ClassMethods
      def messages(success: nil, error: nil)
        self._success_msg = success if success.present?
        self._error_msg = error if error.present?

        true
      end

      def error_from(matcher = nil, message = nil, **match_and_messages)
        _register_error_interceptor(matcher, message, should_report_error: true, **match_and_messages)
      end

      def rescues(matcher = nil, message = nil, **match_and_messages)
        _register_error_interceptor(matcher, message, should_report_error: false, **match_and_messages)
      end

      # ONLY raised exceptions (i.e. NOT fail!). Skipped if exception is rescued via .rescues.
      def on_exception(matcher = -> { true }, &handler)
        raise ArgumentError, "on_exception must be called with a block" unless block_given?

        self._exception_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
      end

      # ONLY raised on fail! (i.e. NOT unhandled exceptions).
      def on_failure(matcher = -> { true }, &handler)
        raise ArgumentError, "on_failure must be called with a block" unless block_given?

        self._failure_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
      end

      # Handles both fail! and unhandled exceptions... but is NOT affected by .rescues
      def on_error(matcher = -> { true }, &handler)
        raise ArgumentError, "on_error must be called with a block" unless block_given?

        self._error_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
      end

      # Syntactic sugar for "after { try" (after, but if it fails do NOT fail the action)
      def on_success(&block)
        raise ArgumentError, "on_success must be called with a block" unless block_given?

        after do
          try { instance_exec(&block) }
        end
      end

      def default_error = new.internal_context.default_error

      # Private helpers

      def _error_interceptor_for(exception:, action:)
        Array(_custom_error_interceptors).detect do |int|
          int.matches?(exception:, action:)
        end
      end

      def _register_error_interceptor(matcher, message, should_report_error:, **match_and_messages)
        method_name = should_report_error ? "error_from" : "rescues"
        raise ArgumentError, "#{method_name} must be called with a key/value pair, or else keyword args" if [matcher, message].compact.size == 1

        interceptors = { matcher => message }.compact.merge(match_and_messages).map do |(matcher, message)| # rubocop:disable Lint/ShadowingOuterLocalVariable
          Action::EventHandlers::CustomErrorInterceptor.new(matcher:, message:, should_report_error:)
        end

        self._custom_error_interceptors += interceptors
      end
    end

    module InstanceMethods
      private

      def fail!(message = nil)
        @context.instance_variable_set("@failure", true)
        @context.error_from_user = message if message.present?

        raise Action::Failure, message
      end

      def try
        yield
      rescue Action::Failure => e
        # NOTE: re-raising so we can still fail! from inside the block
        raise e
      rescue StandardError => e
        trigger_on_exception(e)
      end

      delegate :default_error, to: :internal_context
    end
  end
end
