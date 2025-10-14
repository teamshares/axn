# frozen_string_literal: true

module Axn
  module Mountable
    module Helpers
      # Handles validation logic for Descriptor
      class Validator
        def initialize(descriptor)
          @descriptor = descriptor
        end

        def validate!
          validate_name!
          validate_axn_class_or_block!
          validate_method_name!(@descriptor.name.to_s)
          validate_superclass_and_inherit_conflict!

          if @descriptor.existing_axn_klass
            validate_existing_axn_class!
          elsif @descriptor.block.present?
            validate_callable!(@descriptor.block)
          end
        end

        private

        def validate_name!
          name = @descriptor.name
          invalid!("name must be a string or symbol") unless name.is_a?(String) || name.is_a?(Symbol)
        end

        def validate_axn_class_or_block!
          existing_axn_klass = @descriptor.existing_axn_klass
          block = @descriptor.block

          invalid!("must provide either an axn class or a block") if existing_axn_klass.nil? && block.nil?

          return unless existing_axn_klass.present? && block.present?

          invalid!("cannot provide both an axn class and a block")
        end

        def validate_method_name!(method_name)
          # Check for empty names
          invalid!("method name cannot be empty") if method_name.nil? || method_name == ""

          # Check for whitespace-only names
          invalid!("method name '#{method_name}' must be convertible to a valid constant name") if method_name.strip.empty?

          # Check for names that don't start with a letter (only reject numbers)
          invalid!("method name '#{method_name}' must be convertible to a valid constant name") if method_name.match?(/\A[0-9]/)

          # Check for method suffixes that would conflict with generated methods
          return unless method_name.match?(/[!?=]/)

          invalid!("method name '#{method_name}' cannot contain method suffixes")
        end

        def validate_callable!(callable)
          return if callable.respond_to?(:call)

          invalid!("block must be callable (respond to :call)")
        end

        def validate_superclass_and_inherit_conflict!
          # Check if user explicitly provided superclass in kwargs
          return unless @descriptor.kwargs.key?(:superclass)

          # Get the inherit option value
          inherit_option = @descriptor.options[:inherit]

          # Get the default inherit value for this strategy
          default_inherit = mount_strategy.default_inherit_mode

          # If inherit was explicitly provided and differs from default, raise error
          return if inherit_option == default_inherit

          invalid!("cannot specify both 'superclass:' and 'inherit:' options - use one or the other")
        end

        def validate_existing_axn_class!
          existing_axn_klass = @descriptor.existing_axn_klass

          invalid!("axn class must be a Class") unless existing_axn_klass.is_a?(Class)

          invalid!("axn class must include Axn module") unless existing_axn_klass.included_modules.include?(::Axn) || existing_axn_klass < ::Axn

          # Check raw_kwargs (before preprocessing) to see if user provided any factory kwargs
          # Exclude axn_klass and all strategy-specific kwargs
          user_provided_kwargs = @descriptor.raw_kwargs.except(:axn_klass, *mount_strategy.strategy_specific_kwargs)

          return unless user_provided_kwargs.present? && mount_strategy != MountingStrategies::Step

          invalid!("was given an existing axn class and also keyword arguments - only one is allowed")
        end

        def mount_strategy
          @descriptor.mount_strategy
        end

        def mounting_type_name
          mount_strategy = @descriptor.mount_strategy
          mount_strategy.name.split("::").last.underscore.to_s.humanize
        end

        def invalid!(msg)
          raise MountingError, "#{mounting_type_name} #{msg}"
        end
      end
    end
  end
end
