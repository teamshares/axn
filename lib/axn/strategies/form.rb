# frozen_string_literal: true

module Axn
  class Strategies
    module Form
      # @param expect [Symbol] the attribute name to expect in the context (e.g. :params)
      # @param expose [Symbol] the attribute name to expose in the context (e.g. :form)
      # @param type [Class, String] the form class to use, or a string constant path
      # @param inject [Array<Symbol>] optional additional attributes to include in the form (e.g. [:user, :company])
      # @yield block to define the form class (optional). When type is omitted, the block defines an anonymous form class.
      #   When type is a string and the constant doesn't exist, the block defines the class and it is assigned to that constant.
      def self.configure(expect: :params, expose: :form, type: nil, inject: nil, &block)
        expect ||= :"#{expose.to_s.delete_suffix('_form')}_params"

        # Aliasing to avoid shadowing/any confusion
        expect_attr = expect
        expose_attr = expose

        Module.new do
          extend ActiveSupport::Concern

          included do
            if type.nil? && name.nil? && !block_given?
              raise ArgumentError,
                    "form strategy: must pass explicit :type parameter or a block to `use :form` when applying to anonymous classes"
            end

            resolved_type = Axn::Strategies::Form.resolve_type(type, expose_attr, name, &block)

            # Both halves of this guard are read rather than asked. `Module#===` establishes that a
            # resolved type IS a module before anything is bound to it (a String `type:` naming a
            # constant that holds a plain value resolves to one), the capability comes out of the
            # method table, and the name in the message comes from bound base implementations — a form
            # class defining its own `to_s` is ordinary, and running it here would replace the failure
            # being reported. `public_instance_method?` rather than any-visibility, because the strategy
            # DISPATCHES `valid?` on the form below: a non-public one is not a capability a consumer has.
            unless ::Axn::Internal::Identity.kind?(resolved_type, ::Module) &&
                   ::Axn::Internal::NativeMethods.public_instance_method?(resolved_type, :valid?)
              named = if ::Axn::Internal::Identity.kind?(resolved_type, ::Module)
                        ::Axn::Internal::Rendering.module_name(resolved_type)
                      else
                        ::Axn::Internal::Rendering.class_name(resolved_type)
                      end
              raise ArgumentError, "form strategy: #{named} must implement `valid?`"
            end

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

            # Through the funnel, not by name: this hook is the strategy's own machinery, and a user
            # who takes either name would otherwise lose the exposure (and, worse, the validity gate
            # that decides whether the action fails at all) rather than lose a helper.
            before do
              ::Axn::Internal::ActionState.expose(self, expose_attr => public_send(expose_attr))
              ::Axn::Internal::ActionState.fail!(self) unless public_send(expose_attr).valid?
            end
          end
        end
      end

      # Resolve the form type from the given parameters
      # @param type [Class, String, nil] the form class, constant path, or nil for auto-detection
      # @param expose_attr [Symbol] the attribute name to expose (used for auto-detection)
      # @param action_name [String, nil] the name of the action class (used for auto-detection)
      # @yield block to define the form class (when type is nil = anonymous form; when type is a string and constant doesn't exist = define and assign)
      # @return [Class] the resolved form class
      def self.resolve_type(type, expose_attr, action_name, &)
        # Simplest case: form defined purely by block, no type/constant
        if type.nil? && block_given?
          form_class_name = action_name ? "#{action_name}::#{expose_attr.to_s.classify}" : "AnonymousForm"
          return Class.new(Axn::FormObject).tap do |klass|
            klass.define_singleton_method(:name) { form_class_name }
            klass.class_eval(&)
          end
        end

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
