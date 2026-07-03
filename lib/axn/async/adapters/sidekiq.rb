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

        # Format a resolved facet map ({name => scalar-or-array-of-scalars}) into Sidekiq job-tag
        # strings in "name:value" form. Array-valued facets fan out to one tag per element. Values
        # are already coerced to legal scalars by Core::Tagging.coerce, so this only stringifies.
        def self.job_tags_for(facets)
          facets.flat_map do |name, value|
            Array(value).map { |element| "#{name}:#{element}" }
          end
        end

        # Per-action setup, invoked from Axn::Async#async on every explicit `async :sidekiq`
        # declaration (so subclasses that re-declare get their own worker even though `include`
        # is a no-op for them). Builds a per-action `AxnSidekiqWorker` subclass carrying the
        # action's kwargs + block; skipped for the global-default path (those use DefaultWorker).
        def self._configure_action!(action)
          return if action._async_via_default

          Worker._ensure_sidekiq_job!
          # Build a FRESH subclass each declaration (own const per class in a hierarchy, and no
          # stale options carried over if async is re-declared with different config). sidekiq_options
          # merges, so reusing an existing subclass would silently retain prior settings.
          action.send(:remove_const, :AxnSidekiqWorker) if action.const_defined?(:AxnSidekiqWorker, false)
          subclass = action.const_set(:AxnSidekiqWorker, Class.new(Worker))
          # Block first, then kwargs override — `async :sidekiq, queue: "x" do sidekiq_options queue: "y" end`
          # resolves to "x" (the keyword wins), matching the pre-refactor adapter's precedence.
          subclass.class_eval(&action._async_config_block) if action._async_config_block
          subclass.sidekiq_options(**action._async_config) if action._async_config&.any?
          subclass
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

          # NOTE: the action is intentionally NOT turned into a Sidekiq::Job (so its `new` stays
          # private). The per-action Worker subclass is built in `_configure_action!`, invoked from
          # `async` on every declaration — not here — so subclasses that re-declare async (where
          # `include` is a no-op) still get their own worker.
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

            # The generic worker for this enqueue: the shared DefaultWorker on the global-default
            # path, else this action's dedicated subclass. Inherited const lookup (no `false`) so a
            # child that inherits async config without redeclaring reuses the parent's subclass; the
            # generic perform(name, …) still runs THIS action by name. display_class keeps the Web
            # UI showing the real action name in both cases.
            worker = _async_via_default ? Axn::Async::Adapters::Sidekiq.default_worker : const_get(:AxnSidekiqWorker)

            set_options = { display_class: name }

            # Surface declared facets as Sidekiq job tags (enqueue-time, inputs-only — PRO-2855).
            # Union with any static tags the worker already carries: `.set` overrides the class
            # default, so re-include them explicitly rather than letting them be dropped.
            facet_tags = _resolve_sidekiq_job_tags(kwargs)
            set_options[:tags] = (Array(worker.get_sidekiq_options["tags"]) + facet_tags).uniq if facet_tags.any?

            job = worker.set(**set_options)

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

          # Resolve declared facets to Sidekiq job-tag strings at enqueue time. Input-phase only:
          # builds a throwaway (non-run) instance from the cleaned kwargs and resolves `from: :inputs`
          # facets from the raw inputs (no preprocess/defaults — see Executor#resolve_inbound_facets),
          # for the sources enabled by Axn.config.sidekiq_job_tag_sources. Best-effort — never breaks
          # the enqueue. Skips all work (no instance built) when the sink is disabled or the action
          # declares no facets for the enabled sources. See PRO-2855.
          def _resolve_sidekiq_job_tags(kwargs)
            sources = Axn.config.sidekiq_job_tag_sources
            return [] if sources.empty?

            declares_facets = (sources.include?(:tag) && _tags.any?) || (sources.include?(:dimension) && _dimensions.any?)
            return [] unless declares_facets

            action = send(:new, **kwargs)
            # One resolved map per enabled source (tags/dimensions), kept separate so a name declared
            # as both survives — format each independently and concatenate rather than merging maps.
            maps = Axn::Executor.new(action).resolve_inbound_facets(sources)
            maps.flat_map { |map| Axn::Async::Adapters::Sidekiq.job_tags_for(map) }
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("resolving Sidekiq job tags at enqueue", exception: e)
            []
          end
        end
      end
    end
  end
end

# Teach Axn::Async.owns? about this adapter's generic worker. Covers both the per-action
# `<Action>::AxnSidekiqWorker` subclasses and the global `DefaultWorker` (all `< Worker`). Kept
# here so the wrapper-detection knowledge lives with the adapter that defines the wrapper — a
# future backend registers its own predicate the same way, with no downstream filter change.
Axn::Async.register_ownership_predicate do |klass|
  klass <= Axn::Async::Adapters::Sidekiq::Worker
end
