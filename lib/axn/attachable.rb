# frozen_string_literal: true

require "axn/attachable/attachment_strategies"
require "axn/attachable/descriptor"

module Axn
  module Attachable
    extend ActiveSupport::Concern

    class_methods do
      def _attached_axn_descriptors
        # For inheritance, check if parent has descriptors and copy them
        @_attached_axn_descriptors ||= if superclass.respond_to?(:_attached_axn_descriptors) && superclass._attached_axn_descriptors.any?
                                         _process_inherited_descriptors(superclass._attached_axn_descriptors, from: superclass, to: self)
                                       else
                                         []
                                       end
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
        # Check if :Axns is defined directly on this class (not inherited)
        if const_defined?(:Axns, false)
          axn_class = const_get(:Axns)
          return axn_class if axn_class.is_a?(Class)
        end

        # Create a bare namespace class for holding constants
        client_class = self
        Class.new.tap do |namespace_class|
          namespace_class.define_singleton_method(:__axn_attached_to__) { client_class }

          namespace_class.define_singleton_method(:name) do
            client_name = client_class.name.presence || "AnonymousClient_#{client_class.object_id}"
            "#{client_name}::Axns"
          end

          const_set(:Axns, namespace_class)
        end
      end

      # Handle inheritance of attached axns
      def inherited(subclass)
        super

        # No attached name means built via Class.new (i.e. anonymous class), which is done e.g.
        # via Axn::Factory.build.  That's fine to return from directly -- the case we're trying
        # to manage is, if the user subclasses their DirectoryClass with SpecializedDirectory < Directory,
        # we need to re-apply the axns to be sure any superclass: self is updated to reference the new
        # SpecializedDirectory.
        return if subclass.name.nil?

        # Initialize subclass with a copy of parent's _attached_axn_descriptors to avoid sharing
        copied_axns = _attached_axn_descriptors.map do |descriptor|
          _update_descriptor_for_inheritance(descriptor, from: self, to: subclass)
        end
        subclass.instance_variable_set(:@_attached_axn_descriptors, copied_axns)

        # Mount inherited axn methods on subclasses (only if not already defined)
        subclass._attached_axn_descriptors.each do |descriptor|
          subclass._mount_axn_from_descriptor(descriptor)
        rescue AttachmentError => e
          # Skip if method is already taken (already defined on subclass)
          # or if constant is already defined (inheritance scenario)
          next if e.message.include?("already taken") || e.message.include?("already defined")

          raise
        end
      end

      private

      # Process inherited descriptors: copy, update, and mount them
      def _process_inherited_descriptors(descriptors, from:, to:)
        copied_descriptors = descriptors.map do |descriptor|
          _update_descriptor_for_inheritance(descriptor, from:, to:)
        end

        # Mount the inherited descriptors
        copied_descriptors.each do |descriptor|
          _mount_axn_from_descriptor(descriptor)
        rescue AttachmentError => e
          # Skip if method is already taken (already defined on subclass)
          # or if constant is already defined (inheritance scenario)
          next if e.message.include?("already taken") || e.message.include?("already defined")

          raise
        end

        copied_descriptors
      end

      # Update descriptor kwargs to replace 'from' class references with 'to' class references
      def _update_descriptor_for_inheritance(descriptor, from:, to:)
        duped_descriptor = descriptor.dup

        # Update both raw and processed kwargs
        [_update_kwargs_for_inheritance(duped_descriptor.instance_variable_get(:@raw_kwargs), from:, to:),
         _update_kwargs_for_inheritance(duped_descriptor.instance_variable_get(:@kwargs), from:, to:)].each_with_index do |updated_kwargs, index|
          kwarg_key = index == 0 ? :@raw_kwargs : :@kwargs
          duped_descriptor.instance_variable_set(kwarg_key, updated_kwargs)
        end

        duped_descriptor
      end

      # Update kwargs hash to replace 'from' class references with 'to' class references
      def _update_kwargs_for_inheritance(kwargs, from:, to:)
        updated_kwargs = kwargs.dup

        # Parameters that can contain class references
        %i[superclass include extend prepend].each do |param|
          next unless updated_kwargs.key?(param)

          if updated_kwargs[param].is_a?(Array)
            updated_kwargs[param] = updated_kwargs[param].map { |item| item == from ? to : item }
          elsif updated_kwargs[param] == from
            updated_kwargs[param] = to
          end
        end

        updated_kwargs
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
