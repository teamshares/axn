# frozen_string_literal: true

require "axn/internal/async_serialization"

module Axn
  module Async
    # Shared utilities for async exception reporting across adapters.
    # Used by both Sidekiq (death handler) and ActiveJob (after_discard) to
    # build context and trigger on_exception consistently.
    module ExceptionReporting
      class << self
        # Triggers on_exception for an async job that has been discarded/exhausted.
        #
        # @param exception [Exception] the exception that caused the discard
        # @param action_class [Class] the Axn action class
        # @param retry_context [RetryContext] the retry context
        # @param job_args [Hash] the job arguments (will be filtered)
        # @param extra_context [Hash] additional context to merge (e.g., discarded: true, _job_metadata)
        # @param log_prefix [String] prefix for error logging (e.g., "Sidekiq death handler")
        def trigger_on_exception(exception:, action_class:, retry_context:, job_args:, extra_context: {}, log_prefix: "async")
          # NOTE: deliberately NOT guarded by `_fails_on?`. This is the discard/death-handler path,
          # which only fires after a job exhausts retries or is discarded. A `fails_on` exception
          # settles as `outcome.failure?` and is never re-raised by the adapter (see the
          # `raise … if result.outcome.exception?` gate in the Sidekiq/ActiveJob `perform`), so it
          # never reaches here. Anything that does reach here either was a genuine `exception`
          # outcome (so `_fails_on?` is necessarily false) or bypassed the executor entirely (job
          # deserialization / proxy errors) — and a broad declaration like `fails_on StandardError`
          # must NOT suppress the only global report for those.

          # Filter sensitive values using the action class's internal _context_slice
          filtered_context = action_class._context_slice(data: job_args, direction: :inbound)

          # Build final context with async info (avoid mutating extra_context)
          async_extra = extra_context[:async] || {}
          context = filtered_context.merge(
            async: retry_context.to_h.merge(async_extra),
          ).merge(extra_context.except(:async))

          # Attach declared observability facets (PRO-2853) so an exhausted/discarded-job report
          # carries the same context[:tags]/context[:dimensions] as the synchronous executor path.
          # There's no settled action instance here (the run died in a prior attempt), so facets are
          # resolved best-effort against an instance reconstructed from the (deserialized) job_args:
          # input-derived facets (company_id, record ids) resolve; output-derived ones find no exposes
          # and are skipped per-facet — the same partial-resolution contract as the failure path.
          # Assigned after the merge above, so the framework facets can't be shadowed by a job arg.
          facets = resolve_facets(action_class:, job_args:)
          context[:tags] = facets[:tags] if facets[:tags].any?
          context[:dimensions] = facets[:dimensions] if facets[:dimensions].any?

          # Create proxy action for the on_exception interface
          proxy_action = DiscardedJobAction.new(action_class, exception)

          # Trigger on_exception
          Axn.config.on_exception(exception, action: proxy_action, context:)
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("in #{log_prefix}", exception: e)
        end

        private

        # Best-effort resolution of an action's declared facets on the async exhaustion/discard path,
        # where no live executed instance survives. Reconstructs a bare instance from job_args and
        # resolves against it; Core::Tagging.resolve isolates each resolver (nil omits, a raise is
        # swallowed), so unresolvable (e.g. output-derived) facets simply drop. The returned maps are
        # freshly built and single-use, so no dup_facets copy is needed (unlike the executor path,
        # where the map is memoized and shared across sinks). Returns empty maps on any failure —
        # a facet-less report is always preferable to a lost one.
        def resolve_facets(action_class:, job_args:)
          return { tags: {}, dimensions: {} } unless action_class._tags.any? || action_class._dimensions.any?

          instance = action_class.send(:new, **_deserialize_job_args(job_args))
          {
            tags: Core::Tagging.resolve(action_class._tags, action: instance),
            dimensions: Core::Tagging.resolve(action_class._dimensions, action: instance),
          }
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("resolving facets for async exhaustion report", exception: e)
          { tags: {}, dimensions: {} }
        end

        # Restore the job args to the same live form the worker's `.call` would see, so a facet that
        # reads a GlobalID/model input (or a generated `<field>_id` reader) resolves the real record
        # rather than the serialized `_aj_globalid`/`_as_global_id` wrapper. The Sidekiq death handler
        # hands us the raw serialized payload (only symbolize_keys'd); we re-stringify keys because
        # the fallback GlobalID decoder matches on the `_as_global_id` string suffix. On the ActiveJob
        # path the discard args are already ActiveJob-deserialized (live objects) and re-running the
        # decoder raises ("can only deserialize primitive arguments") — so fall back to the args as-is.
        def _deserialize_job_args(job_args)
          Axn::Internal::AsyncSerialization.deserialize(job_args.transform_keys(&:to_s))
        rescue StandardError
          job_args
        end
      end

      # Proxy action for discarded/dead job reporting that mimics an Axn action instance.
      # Provides the interface expected by on_exception handlers.
      class DiscardedJobAction
        def initialize(action_class, exception)
          @action_class = action_class
          @exception = exception
        end

        def log(message)
          Axn.config.logger.warn("[Axn::DiscardedJob] #{message}")
        end

        def result
          @discarded_job_result ||= DiscardedJobResult.new(@exception)
        end

        def class
          @action_class
        end
      end

      class DiscardedJobResult
        def initialize(exception)
          @exception = exception
        end

        def error
          @exception&.message || "Job was discarded"
        end

        attr_reader :exception
      end
    end
  end
end
