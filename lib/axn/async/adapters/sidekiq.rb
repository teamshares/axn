# frozen_string_literal: true

require_relative "sidekiq/auto_configure"

# Always define the generic Worker const (worker.rb mixes in Sidekiq::Job lazily, so it loads
# even when Sidekiq isn't yet available). This guarantees the const is constantizable in a worker
# process regardless of axn/sidekiq load order or whether any action declared `async :sidekiq`.
require_relative "sidekiq/worker"

module Axn
  module Async
    class Adapters
      module Sidekiq
        extend ActiveSupport::Concern

        def self._running_in_background?
          defined?(::Sidekiq) && ::Sidekiq.server?
        end

        # Build/refresh the worker used for the GLOBAL DEFAULT path. It carries the default's
        # kwargs + block (block first, kwargs override — matching the explicit-async precedence)
        # on a DEDICATED subclass, so explicit per-action workers (which subclass the pristine
        # Worker) never inherit global-default config. Called from Configuration#set_default_async,
        # which runs at boot in every process — so this named const exists (a worker can
        # constantize it) and carries the full config including server-side hooks like
        # sidekiq_retry_in, regardless of load order or whether any action declares `async :sidekiq`.
        def self.configure_default_worker!(config: {}, block: nil)
          return unless defined?(::Sidekiq::Job)

          Worker._ensure_sidekiq_job!
          send(:remove_const, :DefaultWorker) if const_defined?(:DefaultWorker, false)
          worker = const_set(:DefaultWorker, Class.new(Worker))
          worker.class_eval(&block) if block
          worker.sidekiq_options(**config) if config&.any?
          worker
        end

        # The worker for the global-default path, built on demand if set_default_async hasn't yet.
        def self.default_worker
          return const_get(:DefaultWorker, false) if const_defined?(:DefaultWorker, false)

          configure_default_worker!(config: Axn.config._default_async_config, block: Axn.config._default_async_config_block)
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
            Worker._ensure_sidekiq_job!
            const_set(:AxnSidekiqWorker, Class.new(Worker)) unless const_defined?(:AxnSidekiqWorker, false)
            subclass = const_get(:AxnSidekiqWorker, false)
            # Block first, then kwargs override — `async :sidekiq, queue: "x" do sidekiq_options queue: "y" end`
            # resolves to "x" (the keyword wins), matching the pre-refactor adapter's precedence.
            subclass.class_eval(&_async_config_block) if _async_config_block
            subclass.sidekiq_options(**_async_config) if _async_config&.any?
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

            job = if _async_via_default
                    # Global default: no per-action subclass exists in a fresh worker, so route through the
                    # dedicated default worker (which carries the default's kwargs AND block — including
                    # server-side hooks). display_class keeps the Web UI showing the real action.
                    Axn::Async::Adapters::Sidekiq.default_worker.set(display_class: name)
                  else
                    # Explicit async: the per-action subclass already carries the full config
                    # (sidekiq_options + block). Only display_class needs to ride along per-enqueue.
                    # Inherited lookup (no `false`): a child that inherits async config without
                    # redeclaring reuses the parent's subclass — the generic perform(name, …) still
                    # runs THIS action by name. A child that redeclares gets its own (built in included).
                    const_get(:AxnSidekiqWorker).set(display_class: name)
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
