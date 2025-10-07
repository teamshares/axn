# frozen_string_literal: true

require "axn/exceptions"
require "axn/mountable/descriptor"

module Axn
  module Mountable
    class MountingStrategies
      # Base module for all attachment strategies
      module Base
        # Hooks for strategy modules to configure themselves
        def preprocess_kwargs(**kwargs) = kwargs
        def strategy_specific_kwargs = [:_inherit_from_target]

        # The actual per-strategy mounting logic
        def mount(descriptor:, target:)
          mount_to_namespace(descriptor:, target:)
          mount_to_target(descriptor:, target:)
        end

        # Mount methods directly to the target class
        def mount_to_target(descriptor:, target:) = raise NotImplementedError, "Strategy modules must implement mount_to_target"

        def key = name.split("::").last.underscore.to_sym

        # Helper method to define a method on target with collision checking
        def mount_method(target:, method_name:, &)
          # Check if method collision should raise an error
          # We allow overriding if this is a child class with a parent that has axn methods (inheritance scenario)
          # Otherwise, we raise an error for same-class method collisions
          if _should_raise_method_collision_error?(target, method_name)
            raise MountingError, "#{name.split("::").last} unable to attach -- method '#{method_name}' is already taken"
          end

          target.define_singleton_method(method_name, &)
        end

        private

        # Mount methods to the namespace and register the action class
        def mount_to_namespace(descriptor:, target:)
          action_class_builder = Helpers::ClassBuilder.new(descriptor)
          namespace = Helpers::NamespaceManager.get_or_create_namespace(target)
          name = descriptor.name
          descriptor_ref = descriptor

          # Mount methods that delegate to the cached action
          namespace.define_singleton_method(name) do |**kwargs|
            axn = descriptor_ref.mounted_axn_for(target:)
            axn.call(**kwargs)
          end

          namespace.define_singleton_method("#{name}!") do |**kwargs|
            axn = descriptor_ref.mounted_axn_for(target:)
            axn.call!(**kwargs)
          end

          namespace.define_singleton_method("#{name}_async") do |**kwargs|
            axn = descriptor_ref.mounted_axn_for(target:)
            axn.call_async(**kwargs)
          end

          # Register the action class as a constant in the namespace
          action_class_builder.mount(target, name.to_s)
        end

        # Check if we should raise an error for method collision
        # Returns true if method exists AND target is not overriding a parent's method (same-class collision)
        def _should_raise_method_collision_error?(target, method_name)
          return false unless target.respond_to?(method_name)

          # Check if this is an inheritance override by seeing if the parent has the same method
          is_inheritance_override = target.superclass&.respond_to?(method_name)

          # Only raise error if it's a same-class collision (not inheritance override)
          !is_inheritance_override
        end
      end
    end
  end
end
