# frozen_string_literal: true

require "ostruct"

module Axn
  module Attachable
    class AttachmentStrategies
      # Base class for all attachment strategies
      class Base
        def initialize(name:, axn_klass: nil, **kwargs, &block)
          @name = name
          @axn_klass = axn_klass
          @block = block

          @options = kwargs.slice(*strategy_specific_kwargs)
          @kwargs = preprocess_kwargs(**kwargs.except(*strategy_specific_kwargs))
        end

        # Default preprocessing - subclasses can override and call super
        def preprocess_kwargs(**kwargs) = kwargs
        def mount(on:) = raise NotImplementedError, "Subclasses must implement mount"

        def attach_axn!(target:)
          superclass = target.axn_namespace # TODO: make this configurable -- full hydration or standalone proxy class?

          # Use existing class or build new one
          @axn_klass = ::Axn::Factory.wrap(
            @axn_klass,
            superclass:,
            **@kwargs,
            &@block
          )

          # Configure class name and register constant
          ConstantManager.configure_class_name_and_constant(@axn_klass, @name.to_s, target.axn_namespace)

          # Return descriptor for later processing
          Descriptor.new(
            name: @name,
            axn_klass: @axn_klass,
            as: strategy_type,
          )
        end

        def validate!
          block_given = @block.present?

          # Validate name
          raise AttachmentError, "#{attachment_type_name} name must be a string or symbol" unless @name.is_a?(String) || @name.is_a?(Symbol)

          # Validate axn_klass or block requirement
          raise AttachmentError, "#{attachment_type_name} '#{@name}' must be given an existing action class or a block" if @axn_klass.nil? && !block_given

          # Validate axn_klass and block mutual exclusivity
          if @axn_klass && block_given
            raise AttachmentError,
                  "#{attachment_type_name} '#{@name}' was given both an existing action class and a block - only one is allowed"
          end

          # Validate kwargs for non-step attachments
          if @axn_klass && @kwargs.present? && strategy_type != :step
            raise AttachmentError, "#{attachment_type_name} '#{@name}' was given an existing action class and also keyword arguments - only one is allowed"
          end

          # Validate axn_klass inheritance
          return unless @axn_klass && !(@axn_klass.respond_to?(:<) && @axn_klass < ::Axn)

          raise AttachmentError,
                "#{attachment_type_name} '#{@name}' was given an already-existing class #{@axn_klass.name} that does NOT inherit from Axn as expected"
        end

        def validate_before_mount!(on:)
          return unless on.respond_to?(method_name)

          raise AttachmentError, "Unable to attach #{attachment_type_name} -- '#{method_name}' is already taken"
        end

        protected

        def method_name = @name.to_s.underscore

        def attachment_type_name
          self.class.name.split("::").last.underscore.to_s.humanize
        end

        def strategy_type
          self.class.name.split("::").last.underscore.to_sym
        end

        def strategy_specific_kwargs = []
      end
    end
  end
end
