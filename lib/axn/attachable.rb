# frozen_string_literal: true

require "axn/attachable/attachment_types"
require "axn/attachable/validator"
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
        # Get attachment type from registry
        attachment_type = AttachmentTypes.find(as)

        # Preprocessing hook: all attachment types have this method
        kwargs = attachment_type.preprocess_kwargs(**kwargs)

        # Create descriptor for validation (axn_klass might be nil at this point)
        descriptor = Descriptor.new(as:, name:, axn_klass:, kwargs:, block:)

        # Validation logic (centralized)
        descriptor.validate!

        if axn_klass
          # Set proper class name and register constant
          ConstantManager.configure_class_name_and_constant(axn_klass, name, axn_namespace)
        else
          # Filter out attachment-specific kwargs before passing to Factory
          factory_kwargs = kwargs.except(:error_prefix)

          # Build the class and configure it using the proxy namespace
          axn_klass = Axn::Factory.build(superclass: axn_namespace, **factory_kwargs, &block).tap do |built_axn_klass|
            ConstantManager.configure_class_name_and_constant(built_axn_klass, name, axn_namespace)
          end
        end

        # Mount hook: allow attachment type to define methods and configure behavior
        attachment_type.mount(name, axn_klass, on: self, **kwargs)

        # Create final descriptor with the actual axn_klass
        final_descriptor = Descriptor.new(as:, name:, axn_klass:, kwargs:, block:)

        # Store for inheritance (steps are stored but not inherited)
        _attached_axns[name] = final_descriptor

        axn_klass
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

        # Recreate all non-step attachments on subclass (steps are not inherited)
        _attached_axns.each do |name, descriptor|
          next if descriptor.as == :step

          attachment_type = AttachmentTypes.find(descriptor.as)
          attachment_type.mount(name, descriptor.axn_klass, on: subclass, **descriptor.kwargs)
        end
      end
    end

    # Extend DSL methods from attachment types when module is included
    def self.included(base)
      super
      AttachmentTypes.all.each do |(_name, klass)|
        base.extend klass::DSL if klass.const_defined?(:DSL)
      end
    end
  end
end
