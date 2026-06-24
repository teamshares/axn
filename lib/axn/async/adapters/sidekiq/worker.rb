# frozen_string_literal: true

require_relative "auto_configure"

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Generic Sidekiq worker that runs ANY Axn action by name.
        #
        # Actions no longer `include Sidekiq::Job` themselves. Enqueueing an action
        # enqueues THIS worker with the action's class name + serialized kwargs; the
        # worker constantizes the action and calls it.
        #
        # Because the worker only needs `.call` (which every action has), the worker
        # process never needs the async adapter applied to the action. That's what lets
        # the action's `new` stay private AND makes the "rely on the global default in a
        # fresh worker process" path work without any lazy reconfiguration.
        class Worker
          include ::Sidekiq::Job

          def perform(action_class_name, job_kwargs = {})
            # Validate Sidekiq config once on first real execution (skipped in test modes).
            AutoConfigure.validate_configuration!(Axn.config.async_exception_reporting) unless AutoConfigure.skip_validation?

            action_class = action_class_name.constantize
            context = Axn::Internal::AsyncSerialization.deserialize(job_kwargs)

            result = action_class.call(**context)

            # Only re-raise unexpected exceptions so Sidekiq can retry.
            # Axn::Failure is a deliberate business decision (from fail!), not a transient error.
            raise result.exception if result.outcome.exception?

            result
          end
        end
      end
    end
  end
end
