# frozen_string_literal: true

# TODO: maybe namespace those under core?
require "action/core/event_handlers"

module Action
  module Core
    module HandleExceptions
      def self.included(base)
        base.class_eval do
          class_attribute :_success_msg, :_error_msg
          class_attribute :_custom_error_interceptors, default: []
          class_attribute :_error_handlers, default: []
          class_attribute :_exception_handlers, default: []
          class_attribute :_failure_handlers, default: []
          class_attribute :_success_handlers, default: []

          include InstanceMethods
          extend ClassMethods

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

          def trigger_on_success
            # Call success handlers in child-first order (like after hooks)
            self.class._success_handlers.each do |handler|
              instance_exec(&handler)
            rescue StandardError => e
              # Log the error but continue with other handlers
              Axn::Util.piping_error("executing on_success hook", action: self, exception: e)
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

        # Executes when the action completes successfully (after all after hooks complete successfully)
        # Runs in child-first order (child handlers before parent handlers)
        def on_success(&handler)
          raise ArgumentError, "on_success must be called with a block" unless block_given?

          # Prepend like after hooks - child handlers run before parent handlers
          self._success_handlers = [handler] + _success_handlers
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
end
