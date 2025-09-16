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
          default: nil,
          preprocess: nil,
          sensitive: false,
          **validations
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, default:, preprocess:, sensitive:, **validations) if on.present?

          _parse_field_configs(*fields, allow_blank:, allow_nil:, default:, preprocess:, sensitive:, **validations).tap do |configs|
            duplicated = internal_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.internal_field_configs += configs
          end
        end

        def exposes(
          *fields,
          allow_blank: false,
          allow_nil: false,
          default: nil,
          sensitive: false,
          **validations
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPOSURES.include?(field.to_s)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, default:, preprocess: nil, sensitive:, **validations).tap do |configs|
            duplicated = external_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.external_field_configs += configs
          end
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
          default: nil,
          preprocess: nil,
          sensitive: false,
          **validations
        )
          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            _define_field_reader(field)
            FieldConfig.new(field:, validations: parsed_validations, default:, preprocess:, sensitive:)
          end
        end

        def define_memoized_reader_method(field, &block)
          define_method(field) do
            ivar = :"@_memoized_reader_#{field}"
            cached_val = instance_variable_get(ivar)
            return cached_val if cached_val.present?

            value = instance_exec(&block)
            instance_variable_set(ivar, value)
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
          # Apply syntactic sugar for our custom validators
          %i[type model validate].each do |key|
            validations[key] = { with: validations[key] } if validations.key?(key) && !validations[key].is_a?(Hash)
          end

          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            validations.transform_values! do |v|
              { allow_blank:, allow_nil: }.merge(v)
            end
          else
            # Apply default presence validation (unless the type is boolean or params)
            type_values = Array(validations.dig(:type, :with))
            validations[:presence] = true unless validations.key?(:presence) || type_values.include?(:boolean) || type_values.include?(:params)
          end

          fields.map { |field| [field, validations] }
        end
      end

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

        def context_for_logging(direction = nil)
          inspection_filter.filter(@__context.__combined_data.slice(*_declared_fields(direction)))
        end

        private

        def _with_contract
          _apply_inbound_preprocessing!
          _apply_defaults!(:inbound)
          _validate_contract!(:inbound)

          yield

          _apply_defaults!(:outbound)
          _validate_contract!(:outbound)

          # TODO: improve location of this triggering
          @__context.__finalize! # Mark result as finalized
          _trigger_on_success if respond_to?(:_trigger_on_success)
        end

        def _build_context_facade(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

          klass = direction == :inbound ? Axn::InternalContext : Axn::Result
          implicitly_allowed_fields = direction == :inbound ? _declared_fields(:outbound) : []

          klass.new(action: self, context: @__context, declared_fields: _declared_fields(direction), implicitly_allowed_fields:)
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
      end
    end
  end
end
