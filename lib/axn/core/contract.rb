# frozen_string_literal: true

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"

require "axn/core/validation/fields"
require "axn/result"
require "axn/core/context/internal"

module Axn
  module Core
    module Contract
      def self.included(base)
        base.class_eval do
          class_attribute :internal_field_configs, :external_field_configs, default: []

          extend ClassMethods
          include InstanceMethods
        end
      end

      FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive)

      module ClassMethods
        def expects(
          *fields,
          on: nil,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          **validations
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, **validations) if on.present?

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, **validations).tap do |configs|
            duplicated = internal_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.internal_field_configs += configs
          end
        end

        def exposes(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          sensitive: false,
          **validations
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPOSURES.include?(field.to_s)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess: nil, sensitive:, **validations).tap do |configs|
            duplicated = external_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.external_field_configs += configs
          end
        end

        def inspection_filter
          @inspection_filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          (internal_field_configs + external_field_configs + subfield_configs).select(&:sensitive).map(&:field)
        end

        def _declared_fields(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless direction.nil? || %i[inbound outbound].include?(direction)

          configs = case direction
                    when :inbound then internal_field_configs
                    when :outbound then external_field_configs
                    else (internal_field_configs + external_field_configs)
                    end

          configs.map(&:field)
        end

        # Internal method for filtering context data by direction
        # Used by instance methods (inputs_for_logging, outputs_for_logging) and async exception reporting
        def _context_slice(data:, direction: nil)
          inspection_filter.filter(data.slice(*_declared_fields(direction)))
        end

        private

        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! ok?
          inspect default_error
          each_pair
          default_success
          action_name
        ].freeze

        RESERVED_FIELD_NAMES_FOR_EXPOSURES = %w[
          fail! ok?
          inspect each_pair default_error
          ok error success message
          result
          outcome
          exception
          elapsed_time
          finalized?
          __action__
        ].freeze

        def _parse_field_configs(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            _define_field_reader(field)
            FieldConfig.new(field:, validations: parsed_validations, default:, preprocess:, sensitive:)
          end
        end

        def _define_field_reader(field)
          # Allow local access to explicitly-expected fields -- even externally-expected needs to be available locally
          # (e.g. to allow success message callable to reference exposed fields)
          define_method(field) { internal_context.public_send(field) }
        end

        # This method applies any top-level options to each of the individual validations given.
        # It also allows our custom validators to accept a direct value rather than a hash of options.
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          # Apply syntactic sugar for our custom validators (convert shorthand to full hash of options)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields) if validations.key?(:validate)

          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            validations.transform_values! do |v|
              { allow_blank:, allow_nil: }.merge(v)
            end
          else
            # Apply default presence validation (unless the type is boolean or params)
            type_values = Array(validations.dig(:type, :klass))
            validations[:presence] = true unless validations.key?(:presence) || type_values.include?(:boolean) || type_values.include?(:params)
          end

          fields.map { |field| [field, validations] }
        end
      end

      # Reserved keys that cannot be set via set_execution_context or additional_execution_context hook
      RESERVED_EXECUTION_CONTEXT_KEYS = %i[inputs outputs].freeze

      module InstanceMethods
        def internal_context = @internal_context ||= _build_context_facade(:inbound)
        def result = @result ||= _build_context_facade(:outbound)

        delegate :default_error, :default_success, to: :internal_context

        # Accepts either two positional arguments (key, value) or a hash of key/value pairs
        def expose(*args, **kwargs)
          if args.any?
            if args.size != 2
              raise ArgumentError,
                    "expose must be called with exactly two positional arguments (or a hash of key/value pairs)"
            end

            kwargs.merge!(args.first => args.last)
          end

          kwargs.each do |key, value|
            raise Axn::ContractViolation::UnknownExposure, key unless result.respond_to?(key)

            @__context.exposed_data[key] = value
          end
        end

        # Set additional context to be included in execution_context for exception reporting/handlers.
        # This context is NOT included in automatic pre/post logging (which only logs inputs/outputs).
        # Reserved keys (:inputs, :outputs) are stripped before merging.
        def set_execution_context(**kwargs)
          @__additional_execution_context ||= {}
          @__additional_execution_context.merge!(kwargs.except(*RESERVED_EXECUTION_CONTEXT_KEYS))
        end

        # Clear any previously set additional execution context
        def clear_execution_context
          @__additional_execution_context = nil
        end

        # Returns a structured hash for exception reporting and handlers.
        # Contains :inputs, :outputs, and any extra keys from set_execution_context / additional_execution_context hook.
        # Reserved keys (:inputs, :outputs) from extra context are stripped before merging at top level.
        def execution_context
          explicit_context = @__additional_execution_context || {}
          hook_context = respond_to?(:additional_execution_context, true) ? additional_execution_context : {}
          extra_context = explicit_context.merge(hook_context).except(*RESERVED_EXECUTION_CONTEXT_KEYS)

          { inputs: inputs_for_logging, outputs: outputs_for_logging, **extra_context }
        end

        private

        # Filtered inbound fields only (no additional context) - used by automatic logging and execution_context
        def inputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :inbound)
        end

        # Filtered outbound fields only (no additional context) - used by automatic logging and execution_context
        def outputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :outbound)
        end

        def _build_context_facade(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

          klass = direction == :inbound ? Axn::InternalContext : Axn::Result
          implicitly_allowed_fields = direction == :inbound ? self.class._declared_fields(:outbound) : []

          klass.new(action: self, context: @__context, declared_fields: self.class._declared_fields(direction), implicitly_allowed_fields:)
        end
      end
    end
  end
end
