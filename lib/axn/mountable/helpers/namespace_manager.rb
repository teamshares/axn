# frozen_string_literal: true

module Axn
  module Mountable
    module Helpers
      # Handles namespace management for mounting
      module NamespaceManager
        extend self

        def get_or_create_namespace(target)
          # Check if :Axns is defined directly on this class (not inherited)
          if target.const_defined?(:Axns, false)
            axn_class = target.const_get(:Axns)
            return axn_class if axn_class.is_a?(Class)
          end

          # Create a fresh namespace class for this target
          create_namespace_class(target).tap do |namespace_class|
            target.const_set(:Axns, namespace_class) unless target.const_defined?(:Axns, false)
          end
        end

        private

        def create_namespace_class(client_class)
          Class.new do
            define_singleton_method(:__axn_mounted_to__) { client_class }

            define_singleton_method(:name) do
              client_name = client_class.name.presence || "AnonymousClient_#{client_class.object_id}"
              "#{client_name}::Axns"
            end
          end
        end
      end
    end
  end
end
