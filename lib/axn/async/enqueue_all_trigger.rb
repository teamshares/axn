# frozen_string_literal: true

module Axn
  module Async
    # Custom error for missing enqueue_each configuration
    class MissingEnqueueEachError < StandardError; end

    # Shared trigger action for executing batch enqueueing in the background.
    # Called by enqueue_all to iterate over configured fields asynchronously.
    #
    # Configure the async adapter via Axn.config.set_enqueue_all_async,
    # or it defaults to Axn.config.set_default_async.
    #
    # @example Configure a specific queue for all enqueue_all jobs
    #   Axn.configure do |c|
    #     c.set_enqueue_all_async(:sidekiq, queue: :batch)
    #   end
    class EnqueueAllTrigger
      include Axn

      expects :target_class_name
      expects :static_args, default: {}, allow_blank: true

      def call
        target = target_class_name.constantize
        self.class.execute_iteration(target, **static_args.symbolize_keys)
      end

      class << self
        # Entry point for enqueue_all - validates upfront, then executes async
        #
        # @param target [Class] The action class to batch enqueue
        # @param static_args [Hash] Static arguments passed to each job
        # @return [String] Job ID from the async adapter
        def enqueue_for(target, **static_args)
          # 1. Validate async is configured on target
          _validate_async_configured!(target)

          # 2. Handle no-expects case: just call_async directly
          return target.call_async(**static_args) if target.internal_field_configs.empty?

          # 3. Get configs, inferring from model: declarations if none explicit
          configs = _resolve_configs(target)

          # 4. Validate static args upfront (raises ArgumentError if missing)
          _validate_static_args!(target, configs, static_args)

          # 5. Execute iteration in background via EnqueueAllTrigger
          call_async(target_class_name: target.name, static_args:)
        end

        # Execute the actual iteration (called from #call in background)
        def execute_iteration(target, **static_args)
          configs = _resolve_configs(target)
          _iterate(target:, configs:, index: 0, accumulated: {}, static_args:)
          true
        end

        # Override to use enqueue_all-specific async config
        def call_async(...)
          _ensure_enqueue_all_async_configured
          super
        end

        private

        # Returns explicit configs or infers from model: declarations
        def _resolve_configs(target)
          explicit_configs = target._batch_enqueue_configs
          return explicit_configs unless explicit_configs.empty?

          # Try to infer from model: declarations
          inferred = _infer_configs_from_models(target)
          return inferred if inferred.any?

          # No explicit or inferred configs
          raise MissingEnqueueEachError,
                "#{target.name} has expects declarations but no enqueue_each configured " \
                "and no model: declarations that support find_each. " \
                "Add `enqueue_each :field_name, from: -> { ... }` for each field to iterate, " \
                "or use `expects :field, model: SomeModel` where SomeModel responds to find_each."
        end

        # Infer configs from fields with model: declarations whose model responds to find_each
        def _infer_configs_from_models(target)
          target.internal_field_configs.filter_map do |field_config|
            model_config = field_config.validations&.dig(:model)
            next unless model_config

            model_class = model_config[:klass]
            next unless model_class.respond_to?(:find_each)

            # Create an inferred config (equivalent to `enqueue_each :field`)
            BatchEnqueue::Config.new(field: field_config.field, from: nil, via: nil, filter_block: nil)
          end
        end

        def _validate_async_configured!(target)
          return if target._async_adapter.present? && target._async_adapter != false

          raise NotImplementedError,
                "#{target.name} does not have async configured. " \
                "Add `async :sidekiq` or `async :active_job` to enable enqueue_all."
        end

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
