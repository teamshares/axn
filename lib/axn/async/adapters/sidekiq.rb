# frozen_string_literal: true

require_relative "sidekiq/auto_configure"

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

          include ::Sidekiq::Job

          # Sidekiq's processor calls .new on the worker class from outside the class hierarchy
          # (see Sidekiq::Processor#dispatch which does `klass.new`).
          # Since Axn::Core makes :new private, we need to restore it for Sidekiq workers.
          public_class_method :new

          # Apply configuration block if present
          class_eval(&_async_config_block) if _async_config_block

          # Apply kwargs configuration if present
          sidekiq_options(**_async_config) if _async_config&.any?
        end

        class_methods do
          private

          # Implements adapter-specific enqueueing logic for Sidekiq.
          # Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
          def _enqueue_async_job(kwargs)
            # Extract and normalize _async options (removes _async from kwargs)
            normalized_options = _extract_and_normalize_async_options(kwargs)

            # Convert kwargs to string keys and handle GlobalID conversion
            job_kwargs = Axn::Util::GlobalIdSerialization.serialize(kwargs)

            # Process normalized async options if present
            if normalized_options
              if normalized_options["wait_until"]
                return perform_at(normalized_options["wait_until"], job_kwargs)
              elsif normalized_options["wait"]
                return perform_in(normalized_options["wait"], job_kwargs)
              end
            end

            perform_async(job_kwargs)
          end
        end

        def perform(*args)
          context = Axn::Util::GlobalIdSerialization.deserialize(args.first)

          # Validate Sidekiq configuration once on first job execution in a real server context.
          # Skip validation when:
          # - Already validated
          # - In Sidekiq test mode (inline/fake)
          # - In a test environment (where Sidekiq may be stubbed)
          AutoConfigure.validate_configuration!(Axn.config.async_exception_reporting) unless AutoConfigure.skip_validation?

          result = self.class.call(**context)

          # Only re-raise unexpected exceptions so Sidekiq can retry.
          # Axn::Failure is a deliberate business decision (from fail!), not a transient error.
          # Per Sidekiq's ethos: "Sidekiq retries are for unexpected errors."
          raise result.exception if result.outcome.exception?

          result
        end
      end
    end
  end
end
