# frozen_string_literal: true

module Axn
  module Async
    # Shared trigger action for executing batch enqueueing in the background.
    # Used by enqueue_all and enqueue_all_async to iterate over configured fields.
    #
    # Configure the async adapter via Axn.config.set_enqueue_all_async,
    # or it defaults to Axn.config.set_default_async.
    #
    # @example Configure a specific queue for all enqueue_all_async jobs
    #   Axn.configure do |c|
    #     c.set_enqueue_all_async(:sidekiq, queue: :batch)
    #   end
    class EnqueueAllTrigger
      include Axn

      expects :target_class_name
      expects :static_args, default: {}, allow_blank: true

      def call
        target = target_class_name.constantize
        self.class.execute_for(target, **static_args.symbolize_keys)
      end

      class << self
        # Execute batch enqueueing for a target action class
        # Called by both enqueue_all (sync) and EnqueueAllTrigger#call (async)
        def execute_for(target, **static_args)
          configs = target._batch_enqueue_configs

          # Fail helpfully if no enqueue_each was declared
          if configs.nil? || configs.empty?
            raise ArgumentError,
                  "No enqueue_each declared on #{target.name}. " \
                  "Add at least one `enqueue_each :field, from: -> { ... }` declaration."
          end

          # Validate static args
          _validate_static_args!(target, configs, static_args)

          # Execute nested iteration
          _iterate(target:, configs:, index: 0, accumulated: {}, static_args:)
          true
        end

        # Override to use enqueue_all-specific async config
        def call_async(...)
          _ensure_enqueue_all_async_configured
          super
        end

        private

        def _validate_static_args!(target, configs, static_args)
          enqueue_each_fields = configs.map(&:field)
          all_expected_fields = target.internal_field_configs.map(&:field)
          static_fields = all_expected_fields - enqueue_each_fields

          # Check for required static fields (those without defaults and not optional)
          required_static = static_fields.reject do |field|
            field_config = target.internal_field_configs.find { |c| c.field == field }
            next true if field_config&.default.present?
            next true if field_config&.validations&.dig(:allow_blank)

            false
          end

          missing = required_static - static_args.keys
          return unless missing.any?

          raise ArgumentError,
                "Missing required static field(s): #{missing.join(", ")}. " \
                "These fields are not covered by enqueue_each and must be provided."
        end

        def _iterate(target:, configs:, index:, accumulated:, static_args:)
          # Base case: all fields accumulated, enqueue the job
          if index >= configs.length
            target.call_async(**accumulated, **static_args)
            return
          end

          config = configs[index]
          source = config.resolve_source(target:)

          # Use find_each if available (ActiveRecord), otherwise each
          iterator = source.respond_to?(:find_each) ? :find_each : :each

          source.public_send(iterator) do |item|
            # Apply filter block if present
            next if config.filter_block && !config.filter_block.call(item)

            # Apply via extraction if present
            value = config.via ? item.public_send(config.via) : item

            # Recurse to next field
            _iterate(
              target:,
              configs:,
              index: index + 1,
              accumulated: accumulated.merge(config.field => value),
              static_args:,
            )
          end
        end

        def _ensure_enqueue_all_async_configured
          return if _async_adapter.present?
          return unless Axn.config._enqueue_all_async_adapter.present?

          async(
            Axn.config._enqueue_all_async_adapter,
            **Axn.config._enqueue_all_async_config,
            &Axn.config._enqueue_all_async_config_block
          )
        end
      end
    end
  end
end
