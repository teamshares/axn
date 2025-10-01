# frozen_string_literal: true

module Axn
  module Attachable
    class ConstantManager
      def self.configure_class_name_and_constant(axn_klass, name, axn_namespace)
        new(axn_klass, name, axn_namespace).configure
      end

      def initialize(axn_klass, name, axn_namespace)
        @axn_klass = axn_klass
        @name = name
        @axn_namespace = axn_namespace
      end

      def configure
        configure_class_name if name_present?
        register_constant if should_register_constant?
      end

      private

      attr_reader :axn_klass, :name, :axn_namespace

      def name_present?
        name.present?
      end

      def should_register_constant?
        axn_namespace&.name&.end_with?("::AttachedAxns")
      end

      def configure_class_name
        class_name = name.to_s.classify
        namespace_name = axn_namespace&.name

        axn_klass.define_singleton_method(:name) do
          if namespace_name&.end_with?("::AttachedAxns")
            # We're already in a namespace, just add the method name
            "#{namespace_name}::#{class_name}"
          elsif namespace_name
            # Create the AttachedAxns namespace
            "#{namespace_name}::AttachedAxns::#{class_name}"
          else
            # Fallback for anonymous classes
            "AnonymousAxn::#{class_name}"
          end
        end
      end

      def register_constant
        constant_name = generate_constant_name
        axn_namespace.const_set(constant_name, axn_klass)
      end

      def generate_constant_name
        base_name = name.to_s.gsub(/\s+/, "").classify

        # Handle empty or invalid constant names
        base_name = "AnonymousAxn" if base_name.empty? || !base_name.match?(/\A[A-Z]/)

        base_name
      end
    end
  end
end
