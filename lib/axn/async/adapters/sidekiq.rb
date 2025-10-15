# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Sidekiq
        extend ActiveSupport::Concern

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
          def call_async(**kwargs)
            job_kwargs = _params_to_global_id(kwargs)

            if kwargs[:_async].is_a?(Hash)
              options = kwargs.delete(:_async)
              if options[:wait_until]
                return perform_at(options[:wait_until], job_kwargs)
              elsif options[:wait]
                return perform_in(options[:wait], job_kwargs)
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
