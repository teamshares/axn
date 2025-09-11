# frozen_string_literal: true

module Axn
  module Enqueueable
    module ViaSidekiq
      def self.included(base)
        base.class_eval do
          include Sidekiq::Job

          define_method(:perform) do |*args|
            context = self.class._params_from_global_id(args.first)
            bang = args.size > 1 ? args.last : false

            if bang
              self.class.call!(**context)
            else
              self.class.call(**context)
            end
          end

          def self.perform_later(context = {})
            perform_async(_process_context_to_sidekiq_args(context))
          end

          def self.perform_now(context = {})
            call(**context)
          end

          def self.queue_options(opts)
            opts = opts.transform_keys(&:to_s)
            self.sidekiq_options_hash = get_sidekiq_options.merge(opts)
          end

          private

          def self._process_context_to_sidekiq_args(context)
            client = Sidekiq::Client.new

            _params_to_global_id(context).tap do |args|
              if client.send(:json_unsafe?, args).present?
                raise ArgumentError,
                      "Cannot pass non-JSON-serializable objects to Sidekiq. Make sure all expected arguments are serializable (or respond to to_global_id)."
              end
            end
          end

          def self._params_to_global_id(context)
            context.stringify_keys.each_with_object({}) do |(key, value), hash|
              if value.respond_to?(:to_global_id)
                hash["#{key}_as_global_id"] = value.to_global_id.to_s
              else
                hash[key] = value
              end
            end
          end

          def self._params_from_global_id(params)
            params.each_with_object({}) do |(key, value), hash|
              if key.end_with?("_as_global_id")
                hash[key.delete_suffix("_as_global_id")] = GlobalID::Locator.locate(value)
              else
                hash[key] = value
              end
            end.symbolize_keys
          end
        end
      end
    end
  end
end
