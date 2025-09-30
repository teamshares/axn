# frozen_string_literal: true

require "axn/attachable/attachment_types"

module Axn
  module Attachable
    Descriptor = Data.define(:as, :axn_klass, :action_kwargs, :block)

    module Base
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

          # Preprocessing hook: only call if defined
          kwargs = attachment_type.preprocess_kwargs(**kwargs) if attachment_type.respond_to?(:preprocess_kwargs)

          # Validation logic (centralized)
          attachment_type_name = as.to_s.humanize
          raise AttachmentError, "#{attachment_type_name} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)

          method_name = name.to_s.underscore # handle invalid characters in names like "get name" or "SomeCapThing"
          raise AttachmentError, "Unable to attach #{attachment_type_name} -- '#{method_name}' is already taken" if respond_to?(method_name)
          raise AttachmentError, "#{attachment_type_name} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?

          if axn_klass
            if block_given?
              raise AttachmentError,
                    "#{attachment_type_name} '#{name}' was given both an existing action class and a block - only one is allowed"
            end

            # For steps, allow additional kwargs like error_prefix
            if kwargs.present? && as != :step
              raise AttachmentError, "#{attachment_type_name} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
            end

            unless axn_klass.respond_to?(:<) && axn_klass < Axn
              raise AttachmentError,
                    "#{attachment_type_name} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
            end

            # Set proper class name and register constant
            _configure_axn_class_name_and_constant(axn_klass, name, axn_namespace)
          else
            # Filter out attachment-specific kwargs before passing to Factory
            factory_kwargs = kwargs.except(:error_prefix)

            # Build the class and configure it using the proxy namespace
            axn_klass = Axn::Factory.build(superclass: axn_namespace, **factory_kwargs, &block).tap do |built_axn_klass|
              _configure_axn_class_name_and_constant(built_axn_klass, name, axn_namespace)
            end
          end

          # Mount hook: allow attachment type to define methods and configure behavior
          attachment_type.mount(name, axn_klass, on: self, **kwargs)

          # Store for inheritance (steps are stored but not inherited)
          _attached_axns[name] = Descriptor.new(
            as:,
            axn_klass:,
            action_kwargs: kwargs,
            block:,
          )

          axn_klass
        end

        def axn_namespace
          # Check if :AttachedAxns is defined directly on this class (not inherited)
          if const_defined?(:AttachedAxns, false)
            axn_class = const_get(:AttachedAxns)
            return axn_class if axn_class.is_a?(Class)
          end

          # Create the proxy base class using the helper method
          build_proxy_base_class(self)
        end

        private

        # Configure the Axn class name and register it as a constant
        def _configure_axn_class_name_and_constant(axn_klass, name, axn_namespace)
          # Only override the name if one is provided (otherwise keep Factory's default)
          if name.present?
            axn_klass.define_singleton_method(:name) do
              class_name = name.to_s.classify
              if axn_namespace&.name&.end_with?("::AttachedAxns")
                # We're already in a namespace, just add the method name
                "#{axn_namespace.name}::#{class_name}"
              elsif axn_namespace&.name
                # Create the AttachedAxns namespace
                "#{axn_namespace.name}::AttachedAxns::#{class_name}"
              else
                # Fallback for anonymous classes
                "AnonymousAxn::#{class_name}"
              end
            end
          end

          # Register as constant in the namespace if it's a proxy class
          return unless axn_namespace&.name&.end_with?("::AttachedAxns")

          constant_name = name.to_s.gsub(/\s+/, "").classify

          # Handle empty or invalid constant names
          constant_name = "AnonymousAxn" if constant_name.empty? || !constant_name.match?(/\A[A-Z]/)

          # Handle collisions by incrementing the number
          if axn_namespace.const_defined?(constant_name)
            counter = 1
            loop do
              candidate_name = "#{constant_name}#{counter}"
              break unless axn_namespace.const_defined?(candidate_name)

              counter += 1
            end
            constant_name = "#{constant_name}#{counter}"
          end

          axn_namespace.const_set(constant_name, axn_klass)
        end

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
            attachment_type.mount(name, descriptor.axn_klass, on: subclass, **descriptor.action_kwargs)
          end
        end
      end
    end
  end
end
