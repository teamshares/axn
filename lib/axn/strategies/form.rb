# frozen_string_literal: true

module Axn
  class Strategies
    module Form
      # @param expect [Symbol] the attribute name to expect in the context (e.g. :params)
      # @param expose [Symbol] the attribute name to expose in the context (e.g. :form)
      # @param type [Class, String] the form class to use, or a string constant path
      # @param inject [Array<Symbol>] optional additional attributes to include in the form (e.g. [:user, :company])
      # @yield block to define the form class when type is a string and the constant doesn't exist
      def self.configure(expect: :params, expose: :form, type: nil, inject: nil, &block)
        expect ||= :"#{expose.to_s.delete_suffix("_form")}_params"

        # Aliasing to avoid shadowing/any confusion
        expect_attr = expect
        expose_attr = expose

        Module.new do
          extend ActiveSupport::Concern

          included do
            raise ArgumentError, "form strategy: must pass explicit :type parameter to `use :form` when applying to anonymous classes" if type.nil? && name.nil?

            resolved_type = Axn::Strategies::Form.resolve_type(type, expose_attr, name, &block)

            raise ArgumentError, "form strategy: #{resolved_type} must implement `valid?`" unless resolved_type.method_defined?(:valid?)

            expects expect_attr, type: :params
            exposes(expose_attr, type: resolved_type)

            define_method expose_attr do
              attrs_for_form = public_send(expect_attr)&.dup || {}

              Array(inject).each do |ctx|
                attrs_for_form[ctx] = public_send(ctx)
              end

              resolved_type.new(attrs_for_form)
            end
            memo expose_attr

            before do
              expose expose_attr => public_send(expose_attr)
              fail! unless public_send(expose_attr).valid?
            end
          end
        end
      end

      # Resolve the form type from the given parameters
      # @param type [Class, String, nil] the form class, constant path, or nil for auto-detection
      # @param expose_attr [Symbol] the attribute name to expose (used for auto-detection)
      # @param action_name [String, nil] the name of the action class (used for auto-detection)
      # @yield block to define the form class when type is a string and the constant doesn't exist
      # @return [Class] the resolved form class
      def self.resolve_type(type, expose_attr, action_name, &)
        type ||= "#{action_name}::#{expose_attr.to_s.classify}"

        if type.is_a?(Class)
          raise ArgumentError, "form strategy: cannot provide block when type is a Class" if block_given?

          return type
        end

        type.constantize.tap do
          raise ArgumentError, "form strategy: cannot provide block when type constant #{type} already exists" if block_given?
        end
      rescue NameError
        # Constant doesn't exist
        raise ArgumentError, "form strategy: type constant #{type} does not exist and no block provided to define it" unless block_given?

        # Create the class using the block, inheriting from Axn::FormObject
        Class.new(Axn::FormObject).tap do |klass|
          klass.class_eval(&)
          assign_constant(type, klass)
        end
      end

      # Helper method to assign a class to a constant path
      # @param constant_path [String] the full constant path (e.g., "CreateUser::Form")
      # @param klass [Class] the class to assign
      def self.assign_constant(constant_path, klass)
        parts = constant_path.split("::")
        constant_name = parts.pop
        parent_path = parts.join("::")

        if parent_path.empty?
          # Top-level constant
          Object.const_set(constant_name, klass)
        else
          # Nested constant - ensure parent namespace exists
          parent = parent_path.constantize
          parent.const_set(constant_name, klass)
        end
      end
    end
  end
end
