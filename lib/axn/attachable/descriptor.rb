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
        attach_axn_to!(target:)

        mount_strategy.mount(descriptor: self, target:)
      end

      def attached? = @axn.present?

      private

      def attach_axn_to!(target:)
        raise "axn already attached" if attached?

        @attached_axn = @existing_axn_klass || begin
          # TODO: what if in kwargs? how make configurable
          superclass = target.axn_namespace

          Axn::Factory.build(superclass:, **@kwargs, &@block)
        end.tap do |axn|
          configure_class_name_and_constant(axn, @name.to_s, target.axn_namespace)
        end
      end

      def method_name = @name.to_s.underscore

      def validate_before_mount!(target:)
        # Check if the constant is already defined in the AttachedAxns namespace
        constant_name = generate_constant_name(@name.to_s)
        axn_namespace = target.axn_namespace

        # Check if there's already an attached axn with the same name on this target
        return unless axn_namespace.const_defined?(constant_name, false) && (target.respond_to?(:_attached_axn_descriptors) &&
                     target._attached_axn_descriptors.any? { |descriptor| descriptor.name.to_s == @name.to_s })

        # If this is a child class with a parent that has axn methods, allow overriding
        # Check if the constant was defined by a parent class (inheritance scenario)
        if target.superclass && target.superclass.respond_to?(:_attached_axn_descriptors)
          # Check if the parent has a descriptor with the same name
          parent_has_same_descriptor = target.superclass._attached_axn_descriptors.any? { |descriptor| descriptor.name.to_s == @name.to_s }
          return if parent_has_same_descriptor
        end

        invalid!("unable to attach -- constant '#{constant_name}' is already defined in #{axn_namespace.name}")
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

        return unless @existing_axn_klass

        invalid!("was given both an existing axn class and also a block - only one is allowed") if @block.present?
        if @raw_kwargs.present? && mount_strategy != AttachmentStrategies::Step
          invalid!("was given an existing axn class and also keyword arguments - only one is allowed")
        end

        return if @existing_axn_klass.respond_to?(:<) && @existing_axn_klass < ::Axn

        invalid!("was given an already-existing class #{@existing_axn_klass.name} that does NOT inherit from Axn as expected")
      end

      def configure_class_name_and_constant(axn_klass, name, axn_namespace)
        configure_class_name(axn_klass, name, axn_namespace) if name.present?
        register_constant(axn_klass, name, axn_namespace) if should_register_constant?(axn_namespace)
      end

      def configure_class_name(axn_klass, name, axn_namespace)
        class_name = name.to_s.classify

        axn_klass.define_singleton_method(:name) do
          # Evaluate namespace name dynamically when the method is called
          current_namespace_name = axn_namespace&.name

          if current_namespace_name&.end_with?("::AttachedAxns")
            # We're already in a namespace, just add the method name
            "#{current_namespace_name}::#{class_name}"
          elsif current_namespace_name
            # Create the AttachedAxns namespace
            "#{current_namespace_name}::AttachedAxns::#{class_name}"
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
        axn_namespace&.name&.end_with?("::AttachedAxns")
      end

      def generate_constant_name(name)
        base_name = name.to_s.gsub(/\s+/, "").classify

        # Handle empty or invalid constant names
        base_name = "AnonymousAxn" if base_name.empty? || !base_name.match?(/\A[A-Z]/)

        base_name
      end
    end
  end
end
