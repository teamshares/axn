# frozen_string_literal: true

module Axn
  module Attachable
    class Validator
      def self.validate!(descriptor)
        attachment_type_name = descriptor.as.to_s.humanize
        block_given = descriptor.block.present?

        # Validate name
        validate_name!(descriptor.name, attachment_type_name)

        # Validate method name collision
        validate_method_name!(descriptor.name, attachment_type_name)

        # Validate axn_klass or block requirement
        validate_axn_klass_or_block!(descriptor.name, descriptor.axn_klass, block_given, attachment_type_name)

        # Validate axn_klass and block mutual exclusivity
        validate_axn_klass_and_block_exclusivity!(descriptor.name, descriptor.axn_klass, block_given, attachment_type_name)

        # Validate kwargs for non-step attachments
        validate_kwargs!(descriptor.name, descriptor.axn_klass, descriptor.kwargs, descriptor.as, attachment_type_name)

        # Validate axn_klass inheritance
        validate_axn_klass_inheritance!(descriptor.name, descriptor.axn_klass, attachment_type_name) if descriptor.axn_klass
      end

      private

      def self.validate_name!(name, attachment_type_name)
        return if name.is_a?(String) || name.is_a?(Symbol)

        raise AttachmentError, "#{attachment_type_name} name must be a string or symbol"
      end

      def self.validate_method_name!(name, attachment_type_name)
        method_name = name.to_s.underscore
        return unless respond_to?(method_name)

        raise AttachmentError, "Unable to attach #{attachment_type_name} -- '#{method_name}' is already taken"
      end

      def self.validate_axn_klass_or_block!(name, axn_klass, block_given, attachment_type_name)
        return unless axn_klass.nil? && !block_given

        raise AttachmentError, "#{attachment_type_name} '#{name}' must be given an existing action class or a block"
      end

      def self.validate_axn_klass_and_block_exclusivity!(name, axn_klass, block_given, attachment_type_name)
        return unless axn_klass && block_given

        raise AttachmentError,
              "#{attachment_type_name} '#{name}' was given both an existing action class and a block - only one is allowed"
      end

      def self.validate_kwargs!(name, axn_klass, kwargs, as, attachment_type_name)
        return unless axn_klass && kwargs.present? && as != :step

        raise AttachmentError, "#{attachment_type_name} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
      end

      def self.validate_axn_klass_inheritance!(name, axn_klass, attachment_type_name)
        return if axn_klass.respond_to?(:<) && axn_klass < Axn

        raise AttachmentError,
              "#{attachment_type_name} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
      end
    end
  end
end
