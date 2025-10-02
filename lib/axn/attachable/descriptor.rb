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
        mount_on_namespace(target:)
      end

      def attached? = @axn.present?

      private

      def attach_axn_to!(target:)
        raise "axn already attached" if attached?

        @attached_axn = @existing_axn_klass || begin
          Axn::Factory.build(**@kwargs, &@block)
        end.tap do |axn|
          configure_class_name_and_constant(axn, @name.to_s, target.axn_namespace)
        end
      end

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

        invalid!("method name '#{method_name}' must be convertible to a valid constant name (got '#{classified}'). Use letters, numbers, underscores, and common punctuation only.")
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
        namespace = target.axn_namespace
        axn = @attached_axn
        name = @name

        # Mount axn methods on namespace
        namespace.define_singleton_method(name) do |**kwargs|
          axn.call(**kwargs)
        end

        namespace.define_singleton_method("#{name}!") do |**kwargs|
          axn.call!(**kwargs)
        end

        namespace.define_singleton_method("#{name}_async") do |**kwargs|
          axn.call_async(**kwargs)
        end
      end
    end
  end
end
