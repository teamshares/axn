# frozen_string_literal: true

module Axn
  module Core
    module Flow
      module ExceptionExecution
        def self.included(base)
          base.class_eval do
            include InstanceMethods

            def _trigger_on_exception(exception)
              # Check if we're in an async context and should skip based on retry policy
              retry_context = Axn::Async::CurrentRetryContext.current if defined?(Axn::Async::CurrentRetryContext)
              if retry_context
                # Use per-class override if set, otherwise fall back to global config (nil uses default)
                mode = self.class.try(:_async_exception_reporting)
                unless retry_context.should_trigger_on_exception?(mode)
                  # Skip triggering - will be handled by death handler or on a later attempt
                  return
                end
              end

              # Call any handlers registered on *this specific action* class
              # (handlers can call execution_context to get a structured hash with inputs, outputs, and extra keys)
              self.class._dispatch_callbacks(:exception, action: self, exception:)

              # Build enhanced context for global handler
              context = Axn::Util::GlobalExceptionReportingHelpers.build_exception_context(
                action: self,
                retry_context:,
              )

              # Call any global handlers
              Axn.config.on_exception(exception, action: self, context:)
            rescue StandardError => e
              # No action needed -- downstream #on_exception implementation should ideally log any internal failures, but
              # we don't want exception *handling* failures to cascade and overwrite the original exception.
              Axn::Internal::Logging.piping_error("executing on_exception hooks", action: self, exception: e)
            end

            def _trigger_on_success
              # Call success handlers in child-first order (like after hooks)
              self.class._dispatch_callbacks(:success, action: self, exception: nil)
            end
          end
        end

        module InstanceMethods
          private

          def _with_exception_handling
            yield
          rescue Axn::Internal::EarlyCompletion
            # Early completion is not an error - it's a control flow mechanism
            # It should propagate through to be handled by the result builder
            raise
          rescue StandardError => e
            @__context.__record_exception(e)

            # on_error handlers run for both unhandled exceptions and fail!
            self.class._dispatch_callbacks(:error, action: self, exception: e)

            # on_failure handlers run ONLY for fail!
            if e.is_a?(Axn::Failure)
              self.class._dispatch_callbacks(:failure, action: self, exception: e)
            else
              # on_exception handlers run for ONLY for unhandled exceptions.
              _trigger_on_exception(e)
            end
          end
        end
      end
    end
  end
end
