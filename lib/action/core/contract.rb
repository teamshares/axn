# frozen_string_literal: true

require "active_model"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"

require "action/core/contract_validator"
require "action/core/context_facade"

module Action
  module Contract
    def self.included(base)
      base.class_eval do
        class_attribute :internal_field_configs, :external_field_configs, default: []

        extend ClassMethods
        include InstanceMethods
        include ValidationInstanceMethods

        # Remove public context accessor
        remove_method :context

        around do |hooked|
          _apply_inbound_preprocessing!
          _apply_defaults!(:inbound)
          _validate_contract!(:inbound)
          hooked.call
          _apply_defaults!(:outbound)
          _validate_contract!(:outbound)
        end
      end
    end

    FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive)

    module ClassMethods
      def expects(*fields, allow_blank: false, allow_nil: false, default: nil, preprocess: nil, sensitive: false,
                  **validations)
        _parse_field_configs(*fields, allow_blank:, allow_nil:, default:, preprocess:, sensitive:, **validations).tap do |configs|
          duplicated = internal_field_configs.map(&:field) & configs.map(&:field)
          raise Action::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

          # NOTE: avoid <<, which would update value for parents and children
          self.internal_field_configs += configs
        end
      end

      def exposes(*fields, allow_blank: false, allow_nil: false, default: nil, sensitive: false, **validations)
        _parse_field_configs(*fields, allow_blank:, allow_nil:, default:, preprocess: nil, sensitive:, **validations).tap do |configs|
          duplicated = external_field_configs.map(&:field) & configs.map(&:field)
          raise Action::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

          # NOTE: avoid <<, which would update value for parents and children
          self.external_field_configs += configs
        end
      end

      private

      RESERVED_FIELD_NAMES = %w[
        declared_fields inspect fail!
        default_error
        called! rollback! each_pair success? exception ok ok? error success message
      ].freeze

      def _parse_field_configs(*fields, allow_nil: false, allow_blank: false, default: nil, preprocess: nil, sensitive: false,
                               **validations)
        # Allow local access to explicitly-expected fields -- even externally-expected needs to be available locally
        # (e.g. to allow success message callable to reference exposed fields)
        fields.each do |field|
          raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES.include?(field.to_s)

          define_method(field) { internal_context.public_send(field) }
          define_method("#{field}?") { !!internal_context.public_send(field) } if validations[:boolean]
        end

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
        elsif validations.key?(:boolean)
          validations[:presence] = false
        else
          validations[:presence] = true unless validations.key?(:presence)
        end

        fields.map { |field| FieldConfig.new(field:, validations:, default:, preprocess:, sensitive:) }
      end
    end

    module InstanceMethods
      def internal_context = @internal_context ||= _build_context_facade(:inbound)
      def external_context = @external_context ||= _build_context_facade(:outbound)

      # NOTE: ideally no direct access from client code, but we need to expose this for internal Interactor methods
      # (and passing through control methods to underlying context) in order to avoid rewriting internal methods.
      def context = external_context

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
          raise Action::ContractViolation::UnknownExposure, key unless external_context.respond_to?(key)

          @context.public_send("#{key}=", value)
        end
      end

      private

      def _build_context_facade(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        klass = direction == :inbound ? Action::InternalContext : Action::Result
        implicitly_allowed_fields = direction == :inbound ? declared_fields(:outbound) : []

        klass.new(action: self, context: @context, declared_fields: declared_fields(direction), implicitly_allowed_fields:)
      end
    end

    module ValidationInstanceMethods
      def _apply_inbound_preprocessing!
        internal_field_configs.each do |config|
          next unless config.preprocess

          initial_value = @context.public_send(config.field)
          new_value = config.preprocess.call(initial_value)
          @context.public_send("#{config.field}=", new_value)
        rescue StandardError => e
          raise Action::ContractViolation::PreprocessingError, "Error preprocessing field '#{config.field}': #{e.message}"
        end
      end

      def _validate_contract!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        validations = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.validations
        end
        context = direction == :inbound ? internal_context : external_context
        exception_klass = direction == :inbound ? Action::InboundValidationError : Action::OutboundValidationError

        ContractValidator.validate!(validations:, context:, exception_klass:)
      end

      def _apply_defaults!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        defaults_mapping = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.default
        end.compact

        defaults_mapping.each do |field, default_value|
          unless @context.public_send(field)
            @context.public_send("#{field}=",
                                 default_value.respond_to?(:call) ? default_value.call : default_value)
          end
        end
      end

      def context_for_logging(direction = nil)
        inspection_filter.filter(@context.to_h.slice(*declared_fields(direction)))
      end

      protected

      def inspection_filter
        @inspection_filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
      end

      def sensitive_fields
        (internal_field_configs + external_field_configs).select(&:sensitive).map(&:field)
      end

      def declared_fields(direction)
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
