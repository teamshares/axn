# frozen_string_literal: true

require "axn/core/validation/subfields"

module Axn
  module Core
    module ContractForSubfields
      SubfieldConfig = Data.define(:field, :validations, :on, :sensitive, :preprocess, :default, :metadata) do
        def description = metadata[:description]
      end

      def self.included(base)
        base.class_eval do
          class_attribute :subfield_configs, default: []

          extend ClassMethods
        end
      end

      # Resolves the parent value an `on:` points at. `on:` may be a single field/subfield
      # (e.g. :address) or a dotted path (e.g. "address.billing") — the root segment is read via
      # its reader and any remaining segments are dug out via the Extract resolver. Shared by the
      # subfield reader and the inbound validation runner so both treat paths identically.
      def self.resolve_parent(source, on)
        root, *rest = on.to_s.split(".")
        value = source.public_send(root)
        return value if rest.empty?

        Axn::Core::FieldResolvers.resolve(type: :extract, field: rest.join("."), provided_data: value)
      end

      module ClassMethods
        def _expects_subfields(
          *fields,
          on:,
          readers: true,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          **validations
        )
          # `on:` may be a dotted path (e.g. "address.billing"); the *root* segment must be declared.
          root = on.to_s.split(".").first.to_sym
          unless internal_field_configs.map(&:field).include?(root) || subfield_configs.map(&:field).include?(root)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{root}`?)"
          end

          # Writing into an arbitrary nested path isn't supported yet — reject the combination
          # explicitly rather than silently ignoring default:/preprocess: on a nested on:.
          if on.to_s.include?(".") && (default || preprocess)
            raise ArgumentError, "`default:`/`preprocess:` are not supported with a nested (dotted) `on:` (got on: #{on.inspect})"
          end

          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           metadata:, **validations).tap do |configs|
            duplicated = subfield_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.subfield_configs += configs
          end
        end

        private

        def _parse_subfield_configs(
          *fields,
          on:,
          readers:,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          preprocess: nil,
          sensitive: false,
          default: nil,
          metadata: {},
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            SubfieldConfig.new(field:, validations: parsed_validations, on:, sensitive:, preprocess:, default:, metadata:).tap do |config|
              if readers
                _define_subfield_reader(field, on:, validations: parsed_validations)
                _define_boolean_predicate_reader(field) if Axn::Internal::FieldConfig.boolean?(config)
              end
            end
          end
        end

        def _define_subfield_reader(field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{field}` is already defined)" if method_defined?(field)

          Axn::Internal::Memoization.define_memoized_reader_method(self, field) do
            Axn::Core::FieldResolvers.resolve(type: :extract, field:, provided_data: Axn::Core::ContractForSubfields.resolve_parent(self, on))
          end

          _define_subfield_model_reader(field, validations[:model], on:) if validations.key?(:model)
        end

        def _define_subfield_model_reader(field, options, on:)
          # Apply the same syntactic sugar processing as the main contract system
          processed_options = Axn::Validators::ModelValidator.apply_syntactic_sugar(options, [field])

          Axn::Internal::Memoization.define_memoized_reader_method(self, field) do
            # Create a data source that contains the subfield data for the resolver
            subfield_data = Axn::Core::ContractForSubfields.resolve_parent(self, on)

            Axn::Core::FieldResolvers.resolve(
              type: :model,
              field:,
              options: processed_options,
              provided_data: subfield_data,
            )
          end
        end
      end
    end
  end
end
