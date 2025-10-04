# frozen_string_literal: true

module Axn
  module Attachable
    # Descriptor holds the information needed to attach an action
    class Descriptor
      attr_reader :name, :options, :attached_axn, :mount_strategy

      def initialize(name:, as:, axn_klass: nil, block: nil, kwargs: {})
        @mount_strategy = AttachmentStrategies.find(as)
        @existing_axn_klass = axn_klass

        @name = name
        @block = block
        @raw_kwargs = kwargs

        @kwargs = mount_strategy.preprocess_kwargs(**kwargs.except(*mount_strategy.strategy_specific_kwargs))
        @options = kwargs.slice(*mount_strategy.strategy_specific_kwargs)

        validate!
      end

      def mount(target:)
        validate_before_mount!(target:)
        mount_strategy.mount(descriptor: self, target:)
        mount_on_namespace(target:)

        # Register constant immediately for immediate access
        namespace = self.class._get_or_create_namespace(target)
        return unless should_register_constant?(namespace)

        attached_axn = @existing_axn_klass || begin
          # Always use the current target as superclass for inheritance
          Axn::Factory.build(**@kwargs.merge(superclass: target), &@block)
        end
        configure_class_name_and_constant(attached_axn, @name.to_s, namespace)
        configure_axn_attached_to(attached_axn, target)
      end

      def attached_axn_for(target:)
        # Check if the target already has this action class cached
        cache_key = "#{@name}_#{object_id}_#{target.object_id}"

        # Use a class variable to store the cache on the target
        cache_var = :@_axn_cache
        target.instance_variable_set(cache_var, {}) unless target.instance_variable_defined?(cache_var)
        cache = target.instance_variable_get(cache_var)

        return cache[cache_key] if cache.key?(cache_key)

        # Check if constant is already registered
        namespace = self.class._get_or_create_namespace(target)
        constant_name = generate_constant_name(@name.to_s)
        if namespace.const_defined?(constant_name, false)
          attached_axn = namespace.const_get(constant_name)
          cache[cache_key] = attached_axn
          return attached_axn
        end

        # Build action class with current target as superclass
        attached_axn = @existing_axn_klass || begin
          # Always use the current target as superclass for inheritance
          Axn::Factory.build(**@kwargs.merge(superclass: target), &@block)
        end

        configure_class_name_and_constant(attached_axn, @name.to_s, namespace)
        configure_axn_attached_to(attached_axn, target)

        # Cache on the target
        cache[cache_key] = attached_axn
        attached_axn
      end

      def attached? = @attached_axn.present?

      private

      def method_name = @name.to_s.underscore

      def validate_before_mount!(target:)
        # Method name collision validation is now handled in attach_axn
        # This method is kept for potential future validation needs
      end

      def attachment_type_name
        mount_strategy.name.split("::").last.underscore.to_s.humanize
      end

      def invalid!(msg)
        raise AttachmentError, "#{attachment_type_name} #{msg}"
      end

      def validate!
        invalid!("name must be a string or symbol") unless @name.is_a?(String) || @name.is_a?(Symbol)
        invalid!("must be given an existing axn class or a block") if @existing_axn_klass.nil? && !@block.present?

        # Validate method name callability
        validate_method_name!(@name.to_s)

        # Validate callable if it's a block
        validate_callable!(@block) if @block.present? && @existing_axn_klass.nil?

        return unless @existing_axn_klass

        invalid!("was given both an existing axn class and also a block - only one is allowed") if @block.present?
        if @raw_kwargs.present? && mount_strategy != AttachmentStrategies::Step
          invalid!("was given an existing axn class and also keyword arguments - only one is allowed")
        end

        return if @existing_axn_klass.respond_to?(:<) && @existing_axn_klass < ::Axn

        invalid!("was given an already-existing class #{@existing_axn_klass.name} that does NOT inherit from Axn as expected")
      end

      def validate_method_name!(method_name)
        invalid!("method name cannot be empty") if method_name.empty?

        # Check that the name can be converted to a valid constant name
        # Don't allow method suffixes (!?=) in input since they'll be added automatically
        invalid!("method name '#{method_name}' cannot contain method suffixes (!?=) as they are added automatically") if method_name.match?(/[!?=]/)

        classified = method_name.parameterize(separator: "_").classify
        return if classified.match?(/\A[A-Z][A-Za-z0-9_]*\z/)

        invalid!("method name '#{method_name}' must be convertible to a valid constant name (got '#{classified}'). " \
                 "Use letters, numbers, underscores, and common punctuation only.")
      end

      def validate_callable!(callable)
        return unless callable.respond_to?(:parameters)

        args = callable.parameters.group_by(&:first).transform_values(&:count)

        invalid!("callable expects positional arguments") if args[:opt].present? || args[:req].present? || args[:rest].present?
        invalid!("callable expects a splat of keyword arguments") if args[:keyrest].present?

        return unless args[:key].present?

        invalid!("callable expects keyword arguments with defaults (ruby does not allow introspecting)")
      end

      def configure_class_name_and_constant(axn_klass, name, axn_namespace)
        configure_class_name(axn_klass, name, axn_namespace) if name.present?
        register_constant(axn_klass, name, axn_namespace) if should_register_constant?(axn_namespace)
      end

      def configure_axn_attached_to(axn_klass, target)
        axn_klass.define_singleton_method(:__axn_attached_to__) { target }
        axn_klass.define_method(:__axn_attached_to__) { target }
      end

      def configure_class_name(axn_klass, name, axn_namespace)
        class_name = name.to_s.classify

        axn_klass.define_singleton_method(:name) do
          # Evaluate namespace name dynamically when the method is called
          current_namespace_name = axn_namespace&.name

          if current_namespace_name&.end_with?("::Axns")
            # We're already in a namespace, just add the method name
            "#{current_namespace_name}::#{class_name}"
          elsif current_namespace_name
            # Create the Axns namespace
            "#{current_namespace_name}::Axns::#{class_name}"
          else
            # Fallback for anonymous classes
            "AnonymousAxn::#{class_name}"
          end
        end
      end

      def register_constant(axn_klass, name, axn_namespace)
        constant_name = generate_constant_name(name)
        axn_namespace.const_set(constant_name, axn_klass)
      end

      def should_register_constant?(axn_namespace)
        axn_namespace&.name&.end_with?("::Axns")
      end

      def generate_constant_name(name)
        name.to_s.parameterize(separator: "_").classify
      end

      def mount_on_namespace(target:)
        namespace = self.class._get_or_create_namespace(target)
        name = @name

        # Mount methods that delegate to the cached action
        namespace.define_singleton_method(name) do |**kwargs|
          axn = attached_axn_for(target:)
          axn.call(**kwargs)
        end

        namespace.define_singleton_method("#{name}!") do |**kwargs|
          axn = attached_axn_for(target:)
          axn.call!(**kwargs)
        end

        namespace.define_singleton_method("#{name}_async") do |**kwargs|
          axn = attached_axn_for(target:)
          axn.call_async(**kwargs)
        end
      end

      class << self
        def _get_or_create_namespace(target)
          # Check if :Axns is defined directly on this class (not inherited)
          if target.const_defined?(:Axns, false)
            axn_class = target.const_get(:Axns)
            return axn_class if axn_class.is_a?(Class)
          end

          # Create a bare namespace class for holding constants
          client_class = target
          Class.new.tap do |namespace_class|
            namespace_class.define_singleton_method(:__axn_attached_to__) { client_class }

            namespace_class.define_singleton_method(:name) do
              client_name = client_class.name.presence || "AnonymousClient_#{client_class.object_id}"
              "#{client_name}::Axns"
            end

            target.const_set(:Axns, namespace_class)
          end
        end
      end
    end
  end
end
