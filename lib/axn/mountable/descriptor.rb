# frozen_string_literal: true

module Axn
  module Mountable
    # Descriptor holds the information needed to mount an action
    class Descriptor
      attr_reader :name, :options, :mounted_axn, :mount_strategy, :existing_axn_klass, :block, :raw_kwargs, :kwargs

      def initialize(name:, as:, axn_klass: nil, block: nil, kwargs: {})
        @mount_strategy = MountingStrategies.find(as)
        @existing_axn_klass = axn_klass

        @name = name
        @block = block
        @raw_kwargs = kwargs

        @kwargs = mount_strategy.preprocess_kwargs(**kwargs.except(*mount_strategy.strategy_specific_kwargs), axn_klass:)
        @options = kwargs.slice(*mount_strategy.strategy_specific_kwargs)

        @validator = Helpers::Validator.new(self)

        @validator.validate!
        freeze
      end

      def mount(target:)
        validate_before_mount!(target:)
        mount_strategy.mount(descriptor: self, target:)
      end

      def mounted_axn_for(target:)
        # Check if the target already has this action class cached
        cache_key = "#{@name}_#{object_id}_#{target.object_id}"

        # Use a class variable to store the cache on the target
        cache_var = :@_axn_cache
        target.instance_variable_set(cache_var, {}) unless target.instance_variable_defined?(cache_var)
        cache = target.instance_variable_get(cache_var)

        return cache[cache_key] if cache.key?(cache_key)

        # Check if constant is already registered
        action_class_builder = Helpers::ClassBuilder.new(self)
        namespace = action_class_builder.get_or_create_namespace(target)
        constant_name = action_class_builder.generate_constant_name(@name.to_s)
        if namespace.const_defined?(constant_name, false)
          mounted_axn = namespace.const_get(constant_name)
          cache[cache_key] = mounted_axn
          return mounted_axn
        end

        # Build and configure action class
        mounted_axn = action_class_builder.build_and_configure_action_class(target, @name.to_s, namespace)

        # Cache on the target
        cache[cache_key] = mounted_axn
        mounted_axn
      end

      def mounted? = @mounted_axn.present?

      private

      def method_name = @name.to_s.underscore

      def validate_before_mount!(target:)
        # Method name collision validation is now handled in mount_axn
        # This method is kept for potential future validation needs
      end

      def mounting_type_name
        mount_strategy.name.split("::").last.underscore.to_s.humanize
      end
    end
  end
end
