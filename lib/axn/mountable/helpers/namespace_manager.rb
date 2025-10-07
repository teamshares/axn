# frozen_string_literal: true

module Axn
  module Mountable
    module Helpers
      # Handles namespace management for mounting
      class NamespaceManager
        def self.get_or_create_namespace(target)
          # Check if :Axns is defined directly on this class (not inherited)
          if target.const_defined?(:Axns, false)
            axn_class = target.const_get(:Axns)
            return axn_class if axn_class.is_a?(Class)
          end

          # Create a namespace class that inherits from parent's Axns if available
          client_class = target
          parent_axns = find_parent_axns_namespace(client_class)
          namespace_class = create_namespace_class(client_class, parent_axns)

          # Only set the constant if it doesn't exist
          return if target.const_defined?(:Axns, false)

          target.const_set(:Axns, namespace_class)
        end

        private_class_method def self.find_parent_axns_namespace(client_class)
          return nil unless client_class.superclass.respond_to?(:_mounted_axn_descriptors)
          return nil unless client_class.superclass.const_defined?(:Axns, false)

          client_class.superclass.const_get(:Axns)
        end

        private_class_method def self.create_namespace_class(client_class, parent_axns)
          base_class = parent_axns || Class.new

          Class.new(base_class) do
            define_singleton_method(:__axn_mounted_to__) { client_class }

            define_singleton_method(:name) do
              client_name = client_class.name.presence || "AnonymousClient_#{client_class.object_id}"
              "#{client_name}::Axns"
            end
          end.tap do |ns|
            update_inherited_action_classes(ns, client_class) if parent_axns
          end
        end

        private_class_method def self.update_inherited_action_classes(namespace, client_class)
          namespace.constants.each do |const_name|
            const_value = namespace.const_get(const_name)
            next unless const_value.is_a?(Class) && const_value.respond_to?(:__axn_mounted_to__)

            # Update __axn_mounted_to__ method on the existing class
            const_value.define_singleton_method(:__axn_mounted_to__) { client_class }
            const_value.define_method(:__axn_mounted_to__) { client_class }
          end
        end
      end
    end
  end
end
