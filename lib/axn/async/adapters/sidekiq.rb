# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Sidekiq
        extend ActiveSupport::Concern

        def self._running_in_background?
          defined?(Sidekiq) && Sidekiq.server?
        end

        included do
          raise LoadError, "Sidekiq is not available. Please add 'sidekiq' to your Gemfile." unless defined?(::Sidekiq)

          # Use Sidekiq::Job if available (Sidekiq 7+), otherwise error
          raise LoadError, "Sidekiq::Job is not available. Please check your Sidekiq version." unless defined?(::Sidekiq::Job)

          include ::Sidekiq::Job

          # Apply configuration block if present
          class_eval(&_async_config_block) if _async_config_block

          # Apply kwargs configuration if present
          sidekiq_options(**_async_config) if _async_config&.any?
        end

        class_methods do
          # Public method called from instance method perform to convert GlobalID params back to objects
          def _params_from_global_id(params)
            return {} if params.nil?

            params.each_with_object({}) do |(key, value), hash|
              if key.end_with?("_as_global_id")
                hash[key.delete_suffix("_as_global_id")] = GlobalID::Locator.locate(value)
              else
                hash[key] = value
              end
            end.symbolize_keys
          end

          private

          # Implements adapter-specific enqueueing logic for Sidekiq.
          # Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
          def _enqueue_async_job(kwargs)
            # Extract and normalize _async options (removes _async from kwargs)
            normalized_options = _extract_and_normalize_async_options(kwargs)

            # Convert kwargs to string keys and handle GlobalID conversion
            job_kwargs = _params_to_global_id(kwargs)

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

          def _params_to_global_id(context = {})
            return {} if context.nil?

            context.stringify_keys.each_with_object({}) do |(key, value), hash|
              if value.respond_to?(:to_global_id)
                hash["#{key}_as_global_id"] = value.to_global_id.to_s
              else
                hash[key] = value
              end
            end
          end
        end

        def perform(*args)
          context = self.class._params_from_global_id(args.first)

          # Always use bang version so sidekiq can retry if we failed
          self.class.call!(**context)
        end
      end
    end
  end
end
