# frozen_string_literal: true

require "axn/attachable/attachment_strategies"
require "axn/attachable/constant_manager"
require "axn/attachable/descriptor"
require "axn/attachable/proxy_builder"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    class_methods do
      def _attached_axns
        @_attached_axns ||= {}
      end

      def attach_axn(
        as: :axn,
        name: nil,
        axn_klass: nil,
        **kwargs,
        &block
      )
        strategy = AttachmentStrategies.find(as).new(name:, axn_klass:, **kwargs, &block)
        strategy.validate!

        # Create strategy instance and get descriptor
        descriptor = strategy.attach_axn!(target: self)

        # Mount the attachment
        strategy.validate_before_mount!(on: self)
        strategy.mount(on: self)

        # Store for inheritance (steps are stored but not inherited)
        _attached_axns[descriptor.name] = descriptor
      end

      def axn_namespace
        # Check if :AttachedAxns is defined directly on this class (not inherited)
        if const_defined?(:AttachedAxns, false)
          axn_class = const_get(:AttachedAxns)
          return axn_class if axn_class.is_a?(Class)
        end

        # Create the proxy base class using the ProxyBuilder
        ProxyBuilder.build(self)
      end

      private

      # Handle inheritance of attached axns
      def inherited(subclass)
        super

        # Initialize subclass with a copy of parent's _attached_axns to avoid sharing
        copied_axns = _attached_axns.transform_values(&:dup)
        subclass.instance_variable_set(:@_attached_axns, copied_axns)

        # TODO: Implement proper inheritance without infinite recursion
        # For now, inheritance is disabled to avoid stack overflow
      end
    end

    # Extend DSL methods from attachment types when module is included
    def self.included(base)
      super
      AttachmentStrategies.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end
  end
end
