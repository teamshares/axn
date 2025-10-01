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
        # Check if the method name is callable with normal Ruby syntax
        # This is a basic check - more comprehensive validation could be added
        invalid!("method name cannot be empty") if method_name.empty?

        # Check for spaces and other whitespace (these make methods uncallable with normal syntax)
        if method_name.match?(/\s/)
          invalid!("method name '#{method_name}' contains whitespace characters that make it uncallable with normal Ruby syntax. Use underscores instead of spaces")
        end

        # Check for characters that make method names uncallable with normal syntax
        # Allow letters, numbers, underscores, and ending punctuation (!?=)
        if method_name.match?(/[^a-zA-Z0-9_!?=]/)
          invalid!("method name '#{method_name}' contains characters that make it uncallable with normal Ruby syntax. Use only letters, numbers, underscores, and ending punctuation (!?=)")
        end

        # Check that it doesn't start with a number
        return unless method_name.match?(/\A[0-9]/)

        invalid!("method name '#{method_name}' cannot start with a number")
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
        constant_name = generate_unique_constant_name(name, axn_namespace)
        axn_namespace.const_set(constant_name, axn_klass)
      end

      def should_register_constant?(axn_namespace)
        axn_namespace&.name&.end_with?("::AttachedAxns")
      end

      def generate_constant_name(name)
        sanitized_name = sanitize_constant_name(name.to_s)

        # Handle empty or invalid constant names
        sanitized_name = "AnonymousAxn" if sanitized_name.empty? || !sanitized_name.match?(/\A[A-Z]/)

        sanitized_name
      end

      def generate_unique_constant_name(name, axn_namespace)
        base_name = generate_constant_name(name)
        return base_name unless axn_namespace&.const_defined?(base_name, false)

        # If collision, add a number suffix
        counter = 1
        loop do
          candidate = "#{base_name}#{counter}"
          break candidate unless axn_namespace.const_defined?(candidate, false)

          counter += 1
        end
      end

      def sanitize_constant_name(name)
        return "AnonymousAxn" if name.empty?

        # Remove all whitespace characters (spaces, tabs, newlines, etc.)
        sanitized = name.gsub(/\s+/, "")

        # Remove all special characters that are not allowed in constant names
        # Keep only letters, numbers, and underscores
        sanitized = sanitized.gsub(/[^A-Za-z0-9_]/, "")

        # Ensure it starts with a letter or underscore
        sanitized = "Axn#{sanitized}" if sanitized.empty? || !sanitized.match?(/\A[A-Za-z]/)

        # Convert to PascalCase
        sanitized.classify
      end
    end
  end
end
