# frozen_string_literal: true

require "axn/mountable/inherit_profiles"

module Axn
  module Mountable
    module Helpers
      # Handles building and configuring Axn action classes for mounting
      class ClassBuilder
        def initialize(descriptor)
          @descriptor = descriptor
        end

        def mount(target, name)
          namespace = Helpers::NamespaceManager.get_or_create_namespace(target)
          return unless should_register_constant?(namespace)

          build_and_configure_action_class(target, name, namespace)
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
            # Get inherit configuration
            inherit_config = @descriptor.options[:inherit]

            # Determine superclass based on inherit configuration
            factory_kwargs[:superclass] = create_superclass_for_inherit_mode(target, inherit_config)
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

        def create_superclass_for_inherit_mode(target, inherit_config)
          # Handle module targets - convert to a base class first, then apply inherit mode
          target = create_module_base_class(target) if target.is_a?(Module) && !target.is_a?(Class)

          # Resolve inherit configuration to a hash
          resolved_config = InheritProfiles.resolve(inherit_config)

          # If nothing should be inherited, return Object
          return Object if resolved_config.values.none?

          # If everything should be inherited, return target as-is
          return target if resolved_config.values.all?

          # Otherwise, create a class with selective inheritance
          create_class_with_selective_inheritance(target, resolved_config)
        end

        def create_module_base_class(target_module)
          # Create a base class that includes the target module
          # This allows the action class to inherit from a class while still having access to module methods
          Class.new do
            include target_module
          end
        end

        def create_class_with_selective_inheritance(target, inherit_config)
          # Create a class that inherits from target but selectively clears features
          Class.new(target) do
            # Only clear Axn-specific attributes if target includes Axn
            if respond_to?(:internal_field_configs=)
              # Clear fields if not inherited
              unless inherit_config[:fields]
                self.internal_field_configs = []
                self.external_field_configs = []
              end

              # Clear hooks if not inherited
              unless inherit_config[:hooks]
                self.around_hooks = []
                self.before_hooks = []
                self.after_hooks = []
              end

              # Clear callbacks if not inherited
              self._callbacks_registry = Axn::Core::Flow::Handlers::Registry.empty unless inherit_config[:callbacks]

              # Clear messages if not inherited
              self._messages_registry = Axn::Core::Flow::Handlers::Registry.empty unless inherit_config[:messages]

              # Clear async config if not inherited (nil = use Axn.config defaults)
              unless inherit_config[:async]
                self._async_adapter = nil
                self._async_config = nil
                self._async_config_block = nil
              end
            end

            # NOTE: Strategies are always inherited as they're mixed in via `include` and become
            # part of the ancestry chain. This cannot be controlled via the inherit configuration.
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
