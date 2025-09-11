# frozen_string_literal: true

module Axn
  module Enqueueable
    module ViaActiveJob
      def self.included(base)
        base.class_eval do
          def self.perform_later(context = {})
            validated_args = _process_context_to_activejob_args(context)
            # Create a job class that inherits from ActiveJob::Base
            original_class = self
            job_class = Class.new(ActiveJob::Base) do
              define_method(:perform) do |context = {}|
                original_class.call!(**context)
              end

              def self._validate_serializable_arguments(args)
                ActiveJob::Arguments.serialize(args)
              rescue ActiveJob::SerializationError => e
                raise ArgumentError,
                      "Cannot pass non-serializable objects to ActiveJob. " \
                      "Make sure all expected arguments are serializable (or respond to to_global_id). " \
                      "Original error: #{e.message}"
              end
            end
            # Validate the arguments on the job class too
            job_class._validate_serializable_arguments(validated_args)
            job_class.perform_later(validated_args)
          end

          def self.perform_now(context = {})
            call(**context)
          end

          def self.queue_options(opts)
            # Map Sidekiq-style options to ActiveJob equivalents
            return unless opts[:queue]

            queue_as(opts[:queue])

            # Other options like retry, retry_queue are handled by ActiveJob's retry system
          end

          private

          def self._process_context_to_activejob_args(context)
            args = _params_to_global_id(context)
            _validate_serializable_arguments(args)
            args
          end

          def self._validate_serializable_arguments(args)
            ActiveJob::Arguments.serialize(args)
          rescue ActiveJob::SerializationError => e
            raise ArgumentError,
                  "Cannot pass non-serializable objects to ActiveJob. " \
                  "Make sure all expected arguments are serializable (or respond to to_global_id). " \
                  "Original error: #{e.message}"
          end

          # Reuse the GlobalID conversion logic from ViaSidekiq
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
