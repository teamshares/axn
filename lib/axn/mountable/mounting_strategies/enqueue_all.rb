# frozen_string_literal: true

module Axn
  module Mountable
    class MountingStrategies
      # Internal mounting strategy for batch enqueueing.
      # This strategy is used by Axn::Async::BatchEnqueue to create the EnqueueAll action class.
      # It is not intended for direct use - use `enqueue_each` from the Async module instead.
      module EnqueueAll
        include Base
        extend self

        def default_inherit_mode = :async_only

        # No DSL module - the DSL lives in Axn::Async::BatchEnqueue::DSL

        def mount_to_target(descriptor:, target:)
          name = descriptor.name

          mount_method(target:, method_name: name) do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn_instance = axn.send(:new)
            axn_instance._execute_batch_enqueue_with_static_args(**kwargs)
            true # Raise or return true
          end

          mount_method(target:, method_name: "#{name}_async") do |**kwargs|
            axn = descriptor.mounted_axn_for(target: self)
            axn.call_async(**kwargs)
          end
        end

        def mount_to_namespace(descriptor:, target:)
          super

          mounted_axn = descriptor.mounted_axn_for(target:)

          # Define the iteration execution method on the mounted action
          _define_iteration_method(mounted_axn, target)

          # Override the call method to execute the iteration
          # This is needed for when the action is invoked via call_async (background job)
          mounted_axn.define_method(:call) do
            _execute_batch_enqueue_with_static_args
          end
        end

        private

        def _define_iteration_method(mounted_axn, _target)
          # Define method that accepts static args directly (bypasses Axn field system)
          mounted_axn.define_method(:_execute_batch_enqueue_with_static_args) do |**static_args|
            configs = __axn_mounted_to__._batch_enqueue_configs

            # Fail helpfully if no enqueue_each was declared
            if configs.nil? || configs.empty?
              raise ArgumentError,
                    "No enqueue_each declared on #{__axn_mounted_to__.name}. " \
                    "Add at least one `enqueue_each :field, from: -> { ... }` declaration."
            end

            # Validate static args - any expects field not covered by enqueue_each must be provided
            enqueue_each_fields = configs.map(&:field)
            all_expected_fields = __axn_mounted_to__.internal_field_configs.map(&:field)
            static_fields = all_expected_fields - enqueue_each_fields

            # Check for required static fields (those without defaults and not optional)
            required_static = static_fields.reject do |field|
              field_config = __axn_mounted_to__.internal_field_configs.find { |c| c.field == field }
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
            _iterate_nested(configs:, index: 0, accumulated: {}, static_args:)
          end

          mounted_axn.define_method(:_iterate_nested) do |configs:, index:, accumulated:, static_args:|
            # Base case: all fields accumulated, enqueue the job
            if index >= configs.length
              __axn_mounted_to__.call_async(**accumulated, **static_args)
              return
            end

            config = configs[index]
            source = config.resolve_source(target: __axn_mounted_to__)

            # Use find_each if available (ActiveRecord), otherwise each
            iterator = source.respond_to?(:find_each) ? :find_each : :each

            source.public_send(iterator) do |item|
              # Apply filter block if present
              next if config.filter_block && !config.filter_block.call(item)

              # Apply via extraction if present
              value = config.via ? item.public_send(config.via) : item

              # Recurse to next field
              _iterate_nested(
                configs:,
                index: index + 1,
                accumulated: accumulated.merge(config.field => value),
                static_args:,
              )
            end
          end

          # Define enqueue shortcut that calls call_async on the mounted-to class
          mounted_axn.define_method(:enqueue) do |**kwargs|
            __axn_mounted_to__.call_async(**kwargs)
          end
        end
      end
    end
  end
end
