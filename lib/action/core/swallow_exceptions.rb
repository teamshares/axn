# frozen_string_literal: true

module Action
  module SwallowExceptions
    CustomErrorInterceptor = Data.define(:matcher, :message, :should_report_error)
    CustomErrorHandler = Data.define(:matcher, :block)

    class CustomErrorInterceptor
      def self.matches?(matcher:, exception:, action:)
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

      def matches?(exception:, action:)
        self.class.matches?(matcher:, exception:, action:)
      end
    end

    def self.included(base)
      base.class_eval do
        class_attribute :_success_msg, :_error_msg
        class_attribute :_custom_error_interceptors, default: []
        class_attribute :_exception_handlers, default: []

        include InstanceMethods
        extend ClassMethods

        def run_with_exception_swallowing!
          original_run!
        rescue StandardError => e
          raise if e.is_a?(Action::Failure) # TODO: avoid raising if this was passed along from a child action (esp. if wrapped in hoist_errors)

          # Add custom hook for intercepting exceptions (e.g. Teamshares automatically logs to Honeybadger)
          trigger_on_exception(e)

          @context.exception = e

          fail!
        end

        alias_method :original_run!, :run!
        alias_method :run!, :run_with_exception_swallowing!

        # Tweaked to check @context.object_id rather than context (since forwarding object_id causes Ruby to complain)
        # TODO: do we actually need the object_id check? Do we need this override at all?
        def run
          run!
        rescue Action::Failure => e
          raise if @context.object_id != e.context.object_id
        end

        def trigger_on_exception(e)
          interceptor = self.class._error_interceptor_for(exception: e, action: self)
          return if interceptor&.should_report_error == false

          # Call any handlers registered on *this specific action* class
          _on_exception(e)

          # Call any global handlers
          Action.config.on_exception(e,
                                     action: self,
                                     context: respond_to?(:context_for_logging) ? context_for_logging : @context.to_h)
        rescue StandardError => e
          # No action needed -- downstream #on_exception implementation should ideally log any internal failures, but
          # we don't want exception *handling* failures to cascade and overwrite the original exception.
          warn("Ignoring #{e.class.name} in on_exception hook: #{e.message}")
        end

        class << base
          def call_bang_with_unswallowed_exceptions(context = {})
            result = call(context)
            return result if result.ok?

            raise result.exception if result.exception

            raise Action::Failure.new(result.instance_variable_get("@context"), message: result.error)
          end

          alias_method :original_call!, :call!
          alias_method :call!, :call_bang_with_unswallowed_exceptions
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

      def on_exception(matcher = StandardError, &block)
        raise ArgumentError, "on_exception must be called with a block" unless block_given?

        self._exception_handlers += [CustomErrorHandler.new(matcher:, block:)]
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

        { matcher => message }.compact.merge(match_and_messages).each do |(matcher, message)| # rubocop:disable Lint/ShadowingOuterLocalVariable
          self._custom_error_interceptors += [CustomErrorInterceptor.new(matcher:, message:, should_report_error:)]
        end
      end
    end

    module InstanceMethods
      private

      def fail!(message = nil)
        @context.instance_variable_set("@failure", true)
        @context.error_from_user = message if message.present?

        # TODO: should we use context_for_logging here? But doublecheck the one place where we're checking object_id on it...
        raise Action::Failure.new(@context) # rubocop:disable Style/RaiseArgs
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

      def _on_exception(exception)
        handlers = self.class._exception_handlers.select do |this|
          CustomErrorInterceptor.matches?(matcher: this.matcher, exception:, action: self)
        end

        handlers.each do |handler|
          instance_exec(exception, &handler.block)
        rescue StandardError => e
          warn("Ignoring #{e.class.name} in on_exception hook: #{e.message}")
        end
      end
    end
  end
end
