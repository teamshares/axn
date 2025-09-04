# frozen_string_literal: true

module Action
  module Core
    module Flow
      module ExceptionExecution
        def self.included(base)
          base.class_eval do
            include InstanceMethods

            def _trigger_on_exception(exception)
              # Call any handlers registered on *this specific action* class
              self.class._dispatch_callbacks(:exception, action: self, exception:)

              # Call any global handlers
              Action.config.on_exception(exception, action: self, context: context_for_logging)
            rescue StandardError => e
              # No action needed -- downstream #on_exception implementation should ideally log any internal failures, but
              # we don't want exception *handling* failures to cascade and overwrite the original exception.
              Axn::Util.piping_error("executing on_exception hooks", action: self, exception: e)
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
          rescue StandardError => e
            @__context.__record_exception(e)

            # on_error handlers run for both unhandled exceptions and fail!
            self.class._dispatch_callbacks(:error, action: self, exception: e)

            # on_failure handlers run ONLY for fail!
            if e.is_a?(Action::Failure)
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
