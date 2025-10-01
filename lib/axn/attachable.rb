# frozen_string_literal: true

require "axn/attachable/attachment_strategies"
require "axn/attachable/descriptor"
require "axn/attachable/proxy_builder"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    class_methods do
      def _attached_axn_descriptors
        @_attached_axn_descriptors ||= []
      end

      def attach_axn(
        as: :axn,
        name: nil,
        axn_klass: nil,
        **kwargs,
        &block
      )
        descriptor = Descriptor.new(name:, axn_klass:, as:, block:, kwargs:)
        _attached_axn_descriptors << descriptor
        _mount_axn_from_descriptor(descriptor)
      end

      def _mount_axn_from_descriptor(descriptor)
        descriptor.mount(target: self)
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

        # Initialize subclass with a copy of parent's _attached_axn_descriptors to avoid sharing
        copied_axns = _attached_axn_descriptors.map(&:dup) # TODO: if descriptors are frozen, do we need the dup?
        subclass.instance_variable_set(:@_attached_axn_descriptors, copied_axns)

        # Mount inherited axn methods on subclasses (only if not already defined)
        subclass._attached_axn_descriptors.each do |descriptor|
          subclass._mount_axn_from_descriptor(descriptor)
        rescue AttachmentError => e
          # Skip if method is already taken (already defined on subclass)
          next if e.message.include?("already taken")

          raise
        end
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
