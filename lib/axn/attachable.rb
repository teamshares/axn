# frozen_string_literal: true

require "axn/attachable/base"
require "axn/attachable/steps"
require "axn/attachable/subactions"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    included do
      include Base
      include Steps
      include Subactions
    end

    class_methods do
      # Creates a proxy base class that can be used as a superclass for Axn actions
      # The proxy class forwards method calls to the client class through method_missing
      def build_proxy_base_class(client_class)
        # Capture client_class in a local variable for use in closures
        attached_class = client_class

        axn_class = Class.new(client_class) do
          include Axn

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

        # Set a proper name for the class so it can be used as a superclass
        axn_class.define_singleton_method(:name) do
          client_name = attached_class.name
          if client_name
            "#{client_name}::Axn"
          else
            # Use object_id to make anonymous classes unique
            "AnonymousClient_#{attached_class.object_id}::Axn"
          end
        end

        # Make sure it's registered as a class, not a module
        client_class.const_set(:Axn, axn_class)

        axn_class
      end
    end
  end
end
