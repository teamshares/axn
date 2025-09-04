# frozen_string_literal: true

module Axn
  module Attachable
    module Base
      extend ActiveSupport::Concern

      class_methods do
        def axn_for_attachment(
          attachment_type: "Axn",
          name: nil,
          axn_klass: nil,
          superclass: nil,
          **kwargs,
          &block
        )
          raise ArgumentError, "#{attachment_type} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
          raise ArgumentError, "#{attachment_type} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?

          if axn_klass && block_given?
            raise ArgumentError,
                  "#{attachment_type} '#{name}' was given both an existing action class and a block - only one is allowed"
          end

          if axn_klass
            unless axn_klass.respond_to?(:<) && axn_klass < Axn
              raise ArgumentError,
                    "#{attachment_type} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
            end

            if kwargs.present?
              raise ArgumentError, "#{attachment_type} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
            end

            return axn_klass
          end

          Axn::Factory.build(superclass: superclass || self, name:, **kwargs, &block)
        end
      end
    end
  end
end
