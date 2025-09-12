# frozen_string_literal: true

require "active_support/concern"

module Axn
  module Async
    class Adapters
      module Sidekiq
        extend ActiveSupport::Concern

        included do
          raise LoadError, "Sidekiq is not available. Please add 'sidekiq' to your Gemfile." unless defined?(::Sidekiq)

          include ::Sidekiq::Job

          class_eval(&_async_config) if _async_config
        end

        class_methods do
          def call_async(context = {})
            perform_async(_params_to_global_id(context))
          end

          def _params_to_global_id(context)
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
