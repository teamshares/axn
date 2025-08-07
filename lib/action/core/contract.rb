# frozen_string_literal: true

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"

require "action/core/validation/fields"
require "action/core/context_facade"

module Action
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
          return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, default:, preprocess:, sensitive:, **validations) if on.present?

          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, default:, preprocess:, sensitive:, **validations).tap do |configs|
            duplicated = internal_field_configs.map(&:field) & configs.map(&:field)
            raise Action::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

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
            raise Action::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.external_field_configs += configs
          end
        end

        private

        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! success? ok?
          inspect default_error
          each_pair
        ].freeze

        RESERVED_FIELD_NAMES_FOR_EXPOSURES = %w[
          fail! success? ok?
          inspect each_pair default_error
          ok error success message
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
            _define_model_reader(field, parsed_validations[:model]) if parsed_validations.key?(:model)
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

        def _define_model_reader(field, klass)
          name = field.to_s.delete_suffix("_id")
          raise ArgumentError, "Model validation expects to be given a field ending in _id (given: #{field})" unless field.to_s.end_with?("_id")
          raise ArgumentError, "Failed to define model reader - #{name} is already defined" if method_defined?(name)

          define_memoized_reader_method(name) do
            Validators::ModelValidator.instance_for(field:, klass:, id: public_send(field))
          end
        end

        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          if allow_blank
            validations.transform_values! do |v|
              v = { value: v } unless v.is_a?(Hash)
              { allow_blank: true }.merge(v)
            end
          elsif allow_nil
            validations.transform_values! do |v|
              v = { value: v } unless v.is_a?(Hash)
              { allow_nil: true }.merge(v)
            end
          else
            validations[:presence] = true unless validations.key?(:presence) || Array(validations[:type]).include?(:boolean)
          end

          fields.map { |field| [field, validations] }
        end
      end

      module InstanceMethods
        def internal_context = @internal_context ||= _build_context_facade(:inbound)
        def result = @result ||= _build_context_facade(:outbound)

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
            raise Action::ContractViolation::UnknownExposure, key unless result.respond_to?(key)

            @context.public_send("#{key}=", value)
          end
        end

        def context_for_logging(direction = nil)
          inspection_filter.filter(@context.to_h.slice(*_declared_fields(direction)))
        end

        private

        def with_contract
          _apply_inbound_preprocessing!
          _apply_defaults!(:inbound)
          _validate_contract!(:inbound)

          yield

          _apply_defaults!(:outbound)
          _validate_contract!(:outbound)

          # TODO: improve location of this triggering
          trigger_on_success if respond_to?(:trigger_on_success)
        end

        def _build_context_facade(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

          klass = direction == :inbound ? Action::InternalContext : Action::Result
          implicitly_allowed_fields = direction == :inbound ? _declared_fields(:outbound) : []

          klass.new(action: self, context: @context, declared_fields: _declared_fields(direction), implicitly_allowed_fields:)
        end

        def inspection_filter
          @inspection_filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          (internal_field_configs + external_field_configs).select(&:sensitive).map(&:field)
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
