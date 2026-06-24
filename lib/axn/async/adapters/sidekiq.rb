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

          # The action is intentionally NOT turned into a Sidekiq::Job (so its `new` stays private
          # and it carries no Sidekiq class surface).
          #
          # For EXPLICIT `async :sidekiq` we build a per-action Worker subclass and apply the full
          # config — kwargs AND the arbitrary block — to it. Because it's a real Sidekiq::Job, the
          # block can use anything Sidekiq exposes (sidekiq_options, sidekiq_retry_in,
          # sidekiq_retries_exhausted, custom options consumed by middleware, …). A fresh worker
          # reconstructs the subclass by autoloading the action (whose body re-runs `async :sidekiq`),
          # the same mechanism the ActiveJob proxy already relies on.
          #
          # For the GLOBAL DEFAULT path (_async_via_default) we skip the subclass: the action body
          # won't re-create it in a worker, so enqueue routes through the always-present shared
          # Worker instead (see _enqueue_async_job).
          unless _async_via_default
            subclass = Class.new(Worker)
            const_set(:AxnSidekiqWorker, subclass) unless const_defined?(:AxnSidekiqWorker, false)
            subclass = const_get(:AxnSidekiqWorker, false)
            subclass.sidekiq_options(**_async_config) if _async_config&.any?
            subclass.class_eval(&_async_config_block) if _async_config_block
          end
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

            if _async_via_default
              # Global default: no per-action subclass exists in a fresh worker, so use the shared
              # Worker and carry per-job options (from the default config) via .set.
              setter_opts = (_async_config || {}).merge(display_class: name)
              job = Worker.set(**setter_opts)
            else
              # Explicit async: the per-action subclass already carries the full config
              # (sidekiq_options + block). Only display_class needs to ride along per-enqueue.
              job = const_get(:AxnSidekiqWorker, false).set(display_class: name)
            end

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
