# frozen_string_literal: true

module Axn
  module Attachable
    class ProxyBuilder
      def self.build(client_class)
        new(client_class).build
      end

      def initialize(client_class)
        @client_class = client_class
      end

      def build
        axn_class = create_proxy_class
        configure_class_name(axn_class)
        setup_namespace_structure(axn_class)
        configure_axn_namespace_class(axn_class)
        axn_class
      end

      private

      attr_reader :client_class

      def create_proxy_class
        attached_class = client_class

        Class.new(client_class) do
          include ::Axn

          # Store reference to the axn_attached_to class
          define_singleton_method(:axn_attached_to) { attached_class }

          # Proxy class-level methods to the axn_attached_to class
          define_singleton_method(:method_missing) do |method_name, *args, **kwargs, &block|
            if axn_attached_to.respond_to?(method_name)
              axn_attached_to.public_send(method_name, *args, **kwargs, &block)
            else
              super(method_name, *args, **kwargs, &block)
            end
          end

          # Proxy respond_to_missing? for proper method detection
          define_singleton_method(:respond_to_missing?) do |method_name, include_private|
            axn_attached_to.respond_to?(method_name, include_private) || super(method_name, include_private)
          end

          # Proxy instance-level methods to the axn_attached_to class
          define_method(:method_missing) do |method_name, *args, **kwargs, &block|
            if self.class.axn_attached_to.respond_to?(method_name)
              self.class.axn_attached_to.public_send(method_name, *args, **kwargs, &block)
            else
              super(method_name, *args, **kwargs, &block)
            end
          end

          # Proxy respond_to_missing? for proper method detection at instance level
          define_method(:respond_to_missing?) do |method_name, include_private|
            self.class.axn_attached_to.respond_to?(method_name, include_private) || super(method_name, include_private)
          end
        end
      end

      def configure_class_name(axn_class)
        attached_class = client_class
        axn_class.define_singleton_method(:name) do
          client_name = attached_class.name
          if client_name
            "#{client_name}::AttachedAxns"
          else
            # Use object_id to make anonymous classes unique
            "AnonymousClient_#{attached_class.object_id}::AttachedAxns"
          end
        end
      end

      def setup_namespace_structure(axn_class)
        if client_class.const_defined?(:AttachedAxns, false)
          client_class.const_get(:AttachedAxns)
        else
          client_class.const_set(:AttachedAxns, axn_class)
        end
      end

      def configure_axn_namespace_class(axn_class)
        # Set auto_log_level to match the client class (or use default if not set)
        axn_class.auto_log_level = client_class.respond_to?(:auto_log_level) ? client_class.auto_log_level : Axn.config.log_level

        # Inherit async configuration from the client class using the public API
        return unless client_class.respond_to?(:_async_adapter) && client_class._async_adapter

        axn_class.async(client_class._async_adapter, **client_class._async_config || {}, &client_class._async_config_block)

        # Add any other configurations here as they're discovered
        # This centralizes all Axn class configuration in one place
      end
    end
  end
end
