# frozen_string_literal: true

require_relative "sidekiq/auto_configure"

# Define the generic Worker whenever Sidekiq is loaded (so it exists in worker processes
# that dispatch by class name), but stay loadable when Sidekiq is absent — this adapter
# file is required unconditionally by the adapter registry.
require_relative "sidekiq/worker" if defined?(Sidekiq::Job)

module Axn
  module Async
    class Adapters
      module Sidekiq
        extend ActiveSupport::Concern

        def self._running_in_background?
          defined?(::Sidekiq) && ::Sidekiq.server?
        end

        included do
          raise LoadError, "Sidekiq is not available. Please add 'sidekiq' to your Gemfile." unless defined?(::Sidekiq)

          # Use Sidekiq::Job if available (Sidekiq 7+), otherwise error
          raise LoadError, "Sidekiq::Job is not available. Please check your Sidekiq version." unless defined?(::Sidekiq::Job)

          # Safety net for the "axn loaded before sidekiq" ordering: ensure the Worker const
          # exists now that Sidekiq is definitely available (idempotent).
          require_relative "sidekiq/worker"

          # Ensure middleware and death handler are registered for current async_exception_reporting
          # (e.g. when async :sidekiq is used without ever setting async_exception_reporting).
          AutoConfigure.ensure_registered_for_current_config!

          # NOTE: the action is intentionally NOT turned into a Sidekiq::Job. A single generic
          # Worker (see worker.rb) runs every action by name, so the action class stays a plain
          # Axn action (private `new`, no Sidekiq class surface). Per-job options (queue, retry,
          # …) are applied at enqueue time via Worker.set(**_async_config).
        end

        class_methods do
          private

          # Implements adapter-specific enqueueing logic for Sidekiq.
          # Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
          def _enqueue_async_job(kwargs)
            raise ArgumentError, "Cannot enqueue an anonymous Axn action to Sidekiq; assign it to a constant first." if name.nil?

            # Extract and normalize _async options (removes _async from kwargs)
            normalized_options = _extract_and_normalize_async_options(kwargs)

            # Convert kwargs to string keys and handle GlobalID conversion
            job_kwargs = Axn::Internal::AsyncSerialization.serialize(kwargs)

            # Per-action sidekiq options (queue/retry/…) ride along as enqueue-time .set options.
            # display_class keeps the Sidekiq Web UI showing the real action, not the generic Worker.
            setter_opts = (_async_config || {}).merge(display_class: name)
            job = Worker.set(**setter_opts)

            # Process normalized async options if present
            if normalized_options
              if normalized_options["wait_until"]
                return job.perform_at(normalized_options["wait_until"], name, job_kwargs)
              elsif normalized_options["wait"]
                return job.perform_in(normalized_options["wait"], name, job_kwargs)
              end
            end

            job.perform_async(name, job_kwargs)
          end
        end
      end
    end
  end
end
