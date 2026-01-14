# frozen_string_literal: true

require "axn/async/batch_enqueue/config"

module Axn
  module Async
    # BatchEnqueue provides declarative batch enqueueing for Axn actions.
    #
    # Use `enqueue_each` to specify which fields to iterate over when batch enqueueing.
    # This creates `enqueue_all` and `enqueue_all_async` methods on your action class.
    #
    # @example Simple iteration with model inference
    #   class SyncCompany
    #     include Axn
    #     async :sidekiq
    #
    #     expects :company, model: Company
    #
    #     def call
    #       # sync logic
    #     end
    #
    #     enqueue_each :company  # iterates Company.all
    #   end
    #
    #   SyncCompany.enqueue_all  # enqueues a job for each company
    #
    # @example With explicit source
    #   enqueue_each :company, from: -> { Company.active }
    #
    # @example With extraction (passes company_id instead of company object)
    #   enqueue_each :company_id, from: -> { Company.active }, via: :id
    #
    # @example With filter block
    #   enqueue_each :company do |company|
    #     company.active? && !company.in_exit?
    #   end
    #
    # @example Multi-field cross-product
    #   enqueue_each :user, from: -> { User.active }
    #   enqueue_each :company, from: -> { Company.active }
    #   # Produces user_count × company_count jobs
    module BatchEnqueue
      extend ActiveSupport::Concern

      included do
        class_attribute :_batch_enqueue_configs, default: nil
      end

      # DSL methods for batch enqueueing
      module DSL
        # Declare a field to iterate over for batch enqueueing
        #
        # @param field [Symbol] The field name from expects to iterate over
        # @param from [Proc, Symbol, nil] The source collection (lambda, method name, or inferred from model)
        # @param via [Symbol, nil] Optional attribute to extract from each item (e.g., :id)
        # @param block [Proc, nil] Optional filter block - return truthy to enqueue, falsy to skip
        def enqueue_each(field, from: nil, via: nil, &filter_block)
          # Initialize configs array if needed
          self._batch_enqueue_configs ||= []

          # Add this field's config
          config = Config.new(field:, from:, via:, filter_block:)
          self._batch_enqueue_configs += [config]

          # Define enqueue_all methods on first enqueue_each call
          _define_batch_enqueue_methods_if_needed
        end

        private

        def _define_batch_enqueue_methods_if_needed
          # Only define once - check if methods already exist
          return if respond_to?(:enqueue_all)

          # Define enqueue_all class method (synchronous iteration)
          define_singleton_method(:enqueue_all) do |**static_args|
            _execute_batch_enqueue(**static_args)
          end

          # Define enqueue_all_async class method (delegates to shared trigger)
          define_singleton_method(:enqueue_all_async) do |**static_args|
            EnqueueAllTrigger.call_async(target_class_name: name, static_args:)
          end
        end

        def _execute_batch_enqueue(**static_args)
          configs = _batch_enqueue_configs

          # Fail helpfully if no enqueue_each was declared
          if configs.nil? || configs.empty?
            raise ArgumentError,
                  "No enqueue_each declared on #{name}. " \
                  "Add at least one `enqueue_each :field, from: -> { ... }` declaration."
          end

          # Validate static args - any expects field not covered by enqueue_each must be provided
          enqueue_each_fields = configs.map(&:field)
          all_expected_fields = internal_field_configs.map(&:field)
          static_fields = all_expected_fields - enqueue_each_fields

          # Check for required static fields (those without defaults and not optional)
          required_static = static_fields.reject do |field|
            field_config = internal_field_configs.find { |c| c.field == field }
            next true if field_config&.default.present?
            next true if field_config&.validations&.dig(:allow_blank)

            false
          end

          missing = required_static - static_args.keys
          if missing.any?
            raise ArgumentError,
                  "Missing required static field(s): #{missing.join(", ")}. " \
                  "These fields are not covered by enqueue_each and must be provided."
          end

          # Execute nested iteration
          _iterate_batch_enqueue(configs:, index: 0, accumulated: {}, static_args:)
          true
        end

        def _iterate_batch_enqueue(configs:, index:, accumulated:, static_args:)
          # Base case: all fields accumulated, enqueue the job
          if index >= configs.length
            call_async(**accumulated, **static_args)
            return
          end

          config = configs[index]
          source = config.resolve_source(target: self)

          # Use find_each if available (ActiveRecord), otherwise each
          iterator = source.respond_to?(:find_each) ? :find_each : :each

          source.public_send(iterator) do |item|
            # Apply filter block if present
            next if config.filter_block && !config.filter_block.call(item)

            # Apply via extraction if present
            value = config.via ? item.public_send(config.via) : item

            # Recurse to next field
            _iterate_batch_enqueue(
              configs:,
              index: index + 1,
              accumulated: accumulated.merge(config.field => value),
              static_args:,
            )
          end
        end
      end
    end
  end
end
