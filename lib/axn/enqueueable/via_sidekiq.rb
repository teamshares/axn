# frozen_string_literal: true

module Axn
  module Enqueueable
    module ViaSidekiq
      extend ActiveSupport::Concern

      included do
        raise LoadError, "Sidekiq is not available. Please add 'sidekiq' to your Gemfile." unless defined?(Sidekiq)

        include Sidekiq::Job
        class_attribute :sidekiq_options_hash, default: {}
      end

      def self.included(base)
        super
        # Ensure Sidekiq::Job is included even when this module is included in child classes
        base.include Sidekiq::Job unless base.ancestors.include?(Sidekiq::Job)
      end

      class_methods do
        def call_async(context = {})
          perform_async(_process_context_to_sidekiq_args(context))
        end

        def call(context = {})
          # This should delegate to the parent class's call method
          super(**context)
        end

        # Sidekiq configuration methods
        def queue_options(opts)
          opts = opts.transform_keys(&:to_s)
          self.sidekiq_options_hash = (sidekiq_options_hash || {}).merge(opts)
        end

        def queue(name = nil)
          if name
            sidekiq_options queue: name
          else
            sidekiq_options_hash["queue"] || "default"
          end
        end

        def retry_count(count)
          sidekiq_options retry: count
        end

        def retry_queue(name)
          sidekiq_options retry_queue: name
        end

        def sidekiq_options(opts)
          self.sidekiq_options_hash = sidekiq_options_hash.merge(opts.transform_keys(&:to_s))
        end

        private

        def _process_context_to_sidekiq_args(context)
          client = Sidekiq::Client.new

          _params_to_global_id(context).tap do |args|
            if client.send(:json_unsafe?, args).present?
              raise ArgumentError,
                    "Cannot pass non-JSON-serializable objects to Sidekiq. Make sure all expected arguments are serializable (or respond to to_global_id)."
            end
          end
        end

        def _params_to_global_id(context)
          context.stringify_keys.each_with_object({}) do |(key, value), hash|
            if value.respond_to?(:to_global_id)
              hash["#{key}_as_global_id"] = value.to_global_id.to_s
            else
              hash[key] = value
            end
          end
        end

        def _params_from_global_id(params)
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
        bang = args.size > 1 ? args.last : false

        if bang
          self.class.call!(**context)
        else
          self.class.call(**context)
        end
      end
    end
  end
end
