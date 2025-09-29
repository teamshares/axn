# frozen_string_literal: true

module Axn
  module Attachable
    module Base
      extend ActiveSupport::Concern

      class_methods do
        def attach_axn(
          attachment_type: "Axn",
          name: nil,
          axn_klass: nil,
          superclass: nil,
          **kwargs,
          &block
        )
          raise ArgumentError, "#{attachment_type} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
          raise ArgumentError, "#{attachment_type} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?

          if axn_klass
            if block_given?
              raise ArgumentError,
                    "#{attachment_type} '#{name}' was given both an existing action class and a block - only one is allowed"
            end

            if kwargs.present?
              raise ArgumentError, "#{attachment_type} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
            end

            unless axn_klass.respond_to?(:<) && axn_klass < Axn
              raise ArgumentError,
                    "#{attachment_type} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
            end

            # Set proper class name and register constant
            _configure_axn_class_name_and_constant(axn_klass, name, superclass)
            return axn_klass
          end

          # Build the class and configure it
          Axn::Factory.build(superclass: superclass || self, **kwargs, &block).tap do |axn_klass| # rubocop:disable Lint/ShadowingOuterLocalVariable
            _configure_axn_class_name_and_constant(axn_klass, name, superclass)
          end
        end

        private

        # Configure the Axn class name and register it as a constant
        def _configure_axn_class_name_and_constant(axn_klass, name, superclass)
          # Only override the name if one is provided (otherwise keep Factory's default)
          if name.present?
            axn_klass.define_singleton_method(:name) do
              class_name = name.to_s.classify
              if superclass&.name&.end_with?("::Axn")
                # We're already in a namespace, just add the method name
                "#{superclass.name}::#{class_name}"
              elsif superclass&.name
                # Create the Axn namespace
                "#{superclass.name}::Axn::#{class_name}"
              else
                # Fallback for anonymous classes
                "AnonymousAction::#{class_name}"
              end
            end
          end

          # Register as constant in the superclass if it's a namespace
          return unless superclass&.name&.end_with?("::Axn")

          constant_name = name.to_s.classify
          superclass.const_set(constant_name, axn_klass) unless superclass.const_defined?(constant_name)
        end
      end
    end
  end
end
