# frozen_string_literal: true

module Axn
  module Attachable
    module Base
      extend ActiveSupport::Concern

      class_methods do
        def attach_axn(
          as: :axn,
          name: nil,
          axn_klass: nil,
          **kwargs,
          &block
        )
          attachment_type = as.to_s.humanize
          raise AttachmentError, "#{attachment_type} name must be a string or symbol" unless name.is_a?(String) || name.is_a?(Symbol)
          raise AttachmentError, "#{attachment_type} '#{name}' must be given an existing action class or a block" if axn_klass.nil? && !block_given?

          if axn_klass
            if block_given?
              raise AttachmentError,
                    "#{attachment_type} '#{name}' was given both an existing action class and a block - only one is allowed"
            end

            if kwargs.present?
              raise AttachmentError, "#{attachment_type} '#{name}' was given an existing action class and also keyword arguments - only one is allowed"
            end

            unless axn_klass.respond_to?(:<) && axn_klass < Axn
              raise AttachmentError,
                    "#{attachment_type} '#{name}' was given an already-existing class #{axn_klass.name} that does NOT inherit from Axn as expected"
            end

            # Set proper class name and register constant
            _configure_axn_class_name_and_constant(axn_klass, name, axn_namespace)
            return axn_klass
          end

          # Build the class and configure it using the proxy namespace
          Axn::Factory.build(superclass: axn_namespace, **kwargs, &block).tap do |axn_klass| # rubocop:disable Lint/ShadowingOuterLocalVariable
            _configure_axn_class_name_and_constant(axn_klass, name, axn_namespace)
          end
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
      end
    end
  end
end
