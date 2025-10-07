# frozen_string_literal: true

module Axn
  module Mountable
    module DescriptorHelpers
      # Handles building and configuring Axn action classes for mounting
      class ActionClassBuilder
        def initialize(descriptor)
          @descriptor = descriptor
        end

        def mount(target, name)
          namespace = get_or_create_namespace(target)
          return unless should_register_constant?(namespace)

          build_and_configure_action_class(target, name, namespace)
        end

        def get_or_create_namespace(target)
          DescriptorHelpers::NamespaceManager.get_or_create_namespace(target)
        end

        def generate_constant_name(name)
          name.to_s.parameterize(separator: "_").classify
        end

        def build_and_configure_action_class(target, name, namespace)
          mounted_axn = build_action_class(target)
          configure_class_name_and_constant(mounted_axn, name, namespace)
          configure_axn_mounted_to(mounted_axn, target)
          mounted_axn
        end

        private

        def build_action_class(target)
          existing_axn_klass = @descriptor.instance_variable_get(:@existing_axn_klass)
          return existing_axn_klass if existing_axn_klass

          kwargs = @descriptor.instance_variable_get(:@kwargs)
          block = @descriptor.instance_variable_get(:@block)

          # Remove axn_klass from kwargs as it's not a valid parameter for Factory.build
          factory_kwargs = kwargs.except(:axn_klass)

          unless factory_kwargs.key?(:superclass)
            inherit_from_target = @descriptor.options[:_inherit_from_target]

            # Determine superclass based on inherit_from_target option
            factory_kwargs[:superclass] = if inherit_from_target == false
                                            Object
                                          else
                                            # Handle module targets by creating a base class that includes the module
                                            target.is_a?(Module) && !target.is_a?(Class) ? create_module_base_class(target) : target
                                          end
          end

          Axn::Factory.build(**factory_kwargs, &block)
        end

        def configure_class_name_and_constant(axn_klass, name, axn_namespace)
          configure_class_name(axn_klass, name, axn_namespace) if name.present?
          register_constant(axn_klass, name, axn_namespace) if should_register_constant?(axn_namespace)
        end

        def configure_axn_mounted_to(axn_klass, target)
          axn_klass.define_singleton_method(:__axn_mounted_to__) { target }
          axn_klass.define_method(:__axn_mounted_to__) { target }
        end

        def should_register_constant?(axn_namespace)
          axn_namespace&.name&.end_with?("::Axns")
        end

        def create_module_base_class(target_module)
          # Create a base class that includes the target module
          # This allows the action class to inherit from a class while still having access to module methods
          Class.new do
            include target_module
          end
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

          # Only set the constant if it doesn't exist
          return if axn_namespace.const_defined?(constant_name, false)

          axn_namespace.const_set(constant_name, axn_klass)
        end
      end
    end
  end
end
