# frozen_string_literal: true

require "axn/core/validation/subfields"

module Axn
  module Core
    module ContractForSubfields
      # `reader_as` is the generated accessor's name; it defaults to `field` (the subfield key) but
      # `as:`/`prefix:` decouple them — the reader is renamed while the value is still extracted by
      # the wire-key `field` from the `on:` parent.
      SubfieldConfig = Data.define(:field, :validations, :on, :sensitive, :preprocess, :default, :metadata, :reader_as) do
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
        def _expects_subfields( # rubocop:disable Metrics/ParameterLists
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
          reader_names: {},
          **validations
        )
          # `on:` may be a dotted path (e.g. "address.billing"); the *root* segment must be declared.
          # It's resolved by calling the parent's reader (`resolve_parent` → public_send), so it must
          # name a reader — i.e. the alias when the parent was declared with `as:`/`prefix:`, not the
          # underlying wire key (which has no reader of its own once renamed).
          root = on.to_s.split(".").first.to_sym
          unless (internal_field_configs + subfield_configs).map(&:reader_as).include?(root)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such reader exists " \
                  "(are you sure you've declared a field — or alias — named :#{root}?)"
          end

          # default:/preprocess: write into the parent, and sensitive: relies on the log filter
          # matching config.on to a top-level field — none of which support an arbitrary nested
          # path yet. Reject the combination explicitly rather than silently ignoring it (use
          # .nil? for default/preprocess so an explicit `default: false`/`nil` is still caught).
          if on.to_s.include?(".") && (!default.nil? || !preprocess.nil? || sensitive)
            raise ArgumentError,
                  "`default:`/`preprocess:`/`sensitive:` are not supported with a nested (dotted) `on:` (got on: #{on.inspect})"
          end

          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           metadata:, reader_names:, **validations).tap do |configs|
            duplicated = subfield_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.subfield_configs += configs
          end
        end

        private

        def _parse_subfield_configs( # rubocop:disable Metrics/ParameterLists
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
          reader_names: {},
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            reader = reader_names[field] || field
            SubfieldConfig.new(field:, validations: parsed_validations, on:, sensitive:, preprocess:, default:, metadata:, reader_as: reader).tap do |config|
              if readers
                _define_subfield_reader(reader, field, on:, validations: parsed_validations)
                _define_boolean_predicate_reader(reader) if Axn::Internal::FieldConfig.boolean?(config)
              end
            end
          end
        end

        # `reader` is the accessor's name (may be aliased via as:/prefix:); `source_field` is the
        # wire key extracted from the `on:` parent.
        def _define_subfield_reader(reader, source_field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if source_field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{reader}` is already defined)" if method_defined?(reader)

          Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
            Axn::Core::FieldResolvers.resolve(type: :extract, field: source_field,
                                              provided_data: Axn::Core::ContractForSubfields.resolve_parent(self, on))
          end

          _define_subfield_model_reader(reader, source_field, validations[:model], on:) if validations.key?(:model)
        end

        def _define_subfield_model_reader(reader, source_field, options, on:)
          # Apply the same syntactic sugar processing as the main contract system
          processed_options = Axn::Validators::ModelValidator.apply_syntactic_sugar(options, [source_field])

          Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
            # Create a data source that contains the subfield data for the resolver
            subfield_data = Axn::Core::ContractForSubfields.resolve_parent(self, on)

            Axn::Core::FieldResolvers.resolve(
              type: :model,
              field: source_field,
              options: processed_options,
              provided_data: subfield_data,
            )
          end
        end
      end
    end
  end
end
