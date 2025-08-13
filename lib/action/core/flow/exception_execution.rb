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
              self.class._callbacks_registry.for(:exception).each do |handler|
                handler.execute_if_matches(exception:, action: self)
              end

              # Call any global handlers
              Action.config.on_exception(exception, action: self, context: context_for_logging)
            rescue StandardError => e
              # No action needed -- downstream #on_exception implementation should ideally log any internal failures, but
              # we don't want exception *handling* failures to cascade and overwrite the original exception.
              Axn::Util.piping_error("executing on_exception hooks", action: self, exception: e)
            end

            def _trigger_on_success
              # Call success handlers in child-first order (like after hooks)
              self.class._callbacks_registry.for(:success).each do |handler|
                handler.execute_if_matches(exception: nil, action: self)
              rescue StandardError => e
                # Log the error but continue with other handlers
                Axn::Util.piping_error("executing on_success hook", action: self, exception: e)
              end
            end
          end
        end

        module InstanceMethods
          private

          def _with_exception_handling
            yield
          rescue StandardError => e
            # on_error handlers run for both unhandled exceptions and fail!
            self.class._callbacks_registry.for(:error).each { |h| h.execute_if_matches(exception: e, action: self) }

            # on_failure handlers run ONLY for fail!
            if e.is_a?(Action::Failure)
              self.class._callbacks_registry.for(:failure).each { |h| h.execute_if_matches(exception: e, action: self) }
            else
              # on_exception handlers run for ONLY for unhandled exceptions.
              _trigger_on_exception(e)

              @__context.exception = e
            end

            # Set failure state using accessor method
            @__context.send(:failure=, true)
          end

          def try
            yield
          rescue Action::Failure => e
            # NOTE: re-raising so we can still fail! from inside the block
            raise e
          rescue StandardError => e
            _trigger_on_exception(e)
          end
        end
      end
    end
  end
end
