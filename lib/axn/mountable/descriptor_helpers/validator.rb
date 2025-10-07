# frozen_string_literal: true

module Axn
  module Mountable
    module DescriptorHelpers
      # Handles validation logic for Descriptor
      class Validator
        def initialize(descriptor)
          @descriptor = descriptor
        end

        def validate!
          validate_name!
          validate_axn_class_or_block!
          validate_method_name!(@descriptor.instance_variable_get(:@name).to_s)
          if @descriptor.instance_variable_get(:@block).present? && @descriptor.instance_variable_get(:@existing_axn_klass).nil?
            validate_callable!(@descriptor.instance_variable_get(:@block))
          end
          validate_existing_axn_class! if @descriptor.instance_variable_get(:@existing_axn_klass)
        end

        private

        def validate_name!
          name = @descriptor.instance_variable_get(:@name)
          invalid!("name must be a string or symbol") unless name.is_a?(String) || name.is_a?(Symbol)
        end

        def validate_axn_class_or_block!
          existing_axn_klass = @descriptor.instance_variable_get(:@existing_axn_klass)
          block = @descriptor.instance_variable_get(:@block)
          invalid!("must be given an existing axn class or a block") if existing_axn_klass.nil? && !block.present?
        end

        def validate_method_name!(method_name)
          invalid!("method name cannot be empty") if method_name.empty?

          # Check that the name can be converted to a valid constant name
          # Don't allow method suffixes (!?=) in input since they'll be added automatically
          invalid!("method name '#{method_name}' cannot contain method suffixes (!?=) as they are added automatically") if method_name.match?(/[!?=]/)

          classified = method_name.parameterize(separator: "_").classify
          return if classified.match?(/\A[A-Z][A-Za-z0-9_]*\z/)

          invalid!("method name '#{method_name}' must be convertible to a valid constant name (got '#{classified}'). " \
                   "Use letters, numbers, underscores, and common punctuation only.")
        end

        def validate_existing_axn_class!
          existing_axn_klass = @descriptor.instance_variable_get(:@existing_axn_klass)
          block = @descriptor.instance_variable_get(:@block)
          raw_kwargs = @descriptor.instance_variable_get(:@raw_kwargs)
          mount_strategy = @descriptor.instance_variable_get(:@mount_strategy)

          invalid!("was given both an existing axn class and also a block - only one is allowed") if block.present?
          if raw_kwargs.present? && mount_strategy != MountingStrategies::Step
            invalid!("was given an existing axn class and also keyword arguments - only one is allowed")
          end

          return if existing_axn_klass.respond_to?(:<) && existing_axn_klass < ::Axn

          invalid!("was given an already-existing class #{existing_axn_klass.name} that does NOT inherit from Axn as expected")
        end

        def validate_callable!(callable)
          return unless callable.respond_to?(:parameters)

          args = callable.parameters.group_by(&:first).transform_values(&:count)

          invalid!("callable expects positional arguments") if args[:opt].present? || args[:req].present? || args[:rest].present?
          invalid!("callable expects a splat of keyword arguments") if args[:keyrest].present?

          return unless args[:key].present?

          invalid!("callable expects keyword arguments with defaults (ruby does not allow introspecting)")
        end

        def mounting_type_name
          mount_strategy = @descriptor.instance_variable_get(:@mount_strategy)
          mount_strategy.name.split("::").last.underscore.to_s.humanize
        end

        def invalid!(msg)
          raise MountingError, "#{mounting_type_name} #{msg}"
        end
      end
    end
  end
end
