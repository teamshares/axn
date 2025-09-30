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

        # Common proxy logic
        method_missing_proc = proc do |method_name, *args, **kwargs, &block|
          if attached_class.respond_to?(method_name)
            attached_class.public_send(method_name, *args, **kwargs, &block)
          else
            super(method_name, *args, **kwargs, &block)
          end
        end

        respond_to_missing_proc = proc do |method_name, include_private|
          attached_class.respond_to?(method_name, include_private) || super(method_name, include_private)
        end

        Class.new(client_class) do
          include ::Axn

          # Store reference to the axn_attached_to class
          define_singleton_method(:axn_attached_to) { attached_class }

          # Define class-level proxy methods
          define_singleton_method(:method_missing, &method_missing_proc)
          define_singleton_method(:respond_to_missing?, &respond_to_missing_proc)

          # Define instance-level proxy methods
          define_method(:method_missing, &method_missing_proc)
          define_method(:respond_to_missing?, &respond_to_missing_proc)
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
      end
    end
  end
end
