# frozen_string_literal: true

require "ostruct"

module Axn
  module Attachable
    class AttachmentStrategies
      # Base class for all attachment strategies
      class Base
        def self.attach_axn(name:, attachable_instance:, axn_namespace:, axn_klass: nil, **, &)
          new(attachable_instance:, axn_namespace:).attach_axn(name:, axn_klass:, **, &)
        end

        # Default preprocessing - subclasses can override and call super
        def preprocess_kwargs(**kwargs)
          kwargs
        end

        # Default mount - subclasses can override
        def mount(attachment_name, axn_klass, on:, **options)
          # Default implementation does nothing
        end

        def attach_axn(name:, axn_klass: nil, **kwargs, &block)
          # Preprocessing
          kwargs = preprocess_kwargs(**kwargs)

          # Validation
          validate_arguments(name:, axn_klass:, kwargs:, block:)

          # Handle class creation if needed
          if axn_klass
            # Set proper class name and register constant
            ConstantManager.configure_class_name_and_constant(axn_klass, name, @axn_namespace)
          else
            # Filter out attachment-specific kwargs before passing to Factory
            factory_kwargs = kwargs.except(:error_prefix)

            # Build the class and configure it using the proxy namespace
            axn_klass = ::Axn::Factory.build(superclass: @axn_namespace, **factory_kwargs, &block).tap do |built_axn_klass|
              ConstantManager.configure_class_name_and_constant(built_axn_klass, name, @axn_namespace)
            end
          end

          # Mount hook: allow attachment strategy to define methods and configure behavior
          mount(name, axn_klass, on: @attachable_instance, **kwargs)

          # Store for inheritance (steps are stored but not inherited)
          @attachable_instance._attached_axns[name] = OpenStruct.new(as: strategy_type, name:, axn_klass:, kwargs:, block:)

          axn_klass
        end

        # Initialize with the attachable instance and namespace
        def initialize(attachable_instance:, axn_namespace:)
          @attachable_instance = attachable_instance
          @axn_namespace = axn_namespace
        end

        def strategy_type
          self.class.name.split("::").last.underscore.to_sym
        end

        def validate_arguments(name:, axn_klass:, kwargs:, block:)
          attachment_type_name = self.class.attachment_type_name.to_s.humanize
          block_given = block.present?

          # Validate name
          raise AttachmentError, "#{attachment_type_name} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)

          # Validate method name collision
          method_name = name.to_s.underscore
          if @attachable_instance.respond_to?(method_name)
            raise AttachmentError, "Unable to attach #{attachment_type_name} -- '#{method_name}' is already taken"
          end

          # Validate axn_klass or block requirement
          raise AttachmentError, "#{attachment_type_name} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given

          # Validate axn_klass and block mutual exclusivity
          if axn_klass && block_given
            raise AttachmentError,
                  "#{attachment_type_name} '#{name}' was given both an existing action class and a block - only one is allowed"
          end

          # Validate kwargs for non-step attachments
          if axn_klass && kwargs.present? && strategy_type != :step
            raise AttachmentError, "#{attachment_type_name} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
          end

          # Validate axn_klass inheritance
          return unless axn_klass && !(axn_klass.respond_to?(:<) && axn_klass < ::Axn)

          raise AttachmentError,
                "#{attachment_type_name} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
        end
      end
    end
  end
end
