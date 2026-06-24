# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"

require "axn/core/validation/fields"
require "axn/core/flow/handlers/invoker"
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

      # `reader_as` is the name of the generated accessor method. It defaults to `field` (the wire
      # key), but `expects ..., as:`/`prefix:` decouple them so the caller-facing contract stays
      # `field` while the in-action reader gets its own name.
      FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive, :metadata, :reader_as, :user_facing) do
        def description = metadata[:description]
      end

      # One member declared inside a structured field's block (`field :name, ...`).
      # Nested members live in validations[:shape][:members], so the tree is uniform
      # at every depth and walked by both ShapeValidator (runtime) and axn-mcp (schema).
      ShapeConfig = Data.define(:field, :validations, :metadata) do
        def description = metadata[:description]
      end

      # Collector for the `field ...` calls inside a structured field's block.
      class ShapeBuilder
        attr_reader :declarations

        def initialize
          @declarations = []
        end

        def field(name, **opts, &block)
          @declarations << [name, opts, block]
        end
      end

      module ClassMethods
        # rubocop:disable Metrics/ParameterLists
        def expects(
          *fields,
          on: nil,
          readers: true,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          as: nil,
          prefix: nil,
          user_facing: false,
          **,
          &block
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          raise ArgumentError, "readers: false is only valid for subfields (use with on:)" if readers == false && on.nil?

          _validate_user_facing!(user_facing)
          raise ArgumentError, "user_facing: is not supported with on: (subfields are always dev-facing)" if user_facing && on.present?
          # A shape block validates nested members, which `ShapeValidator` reports under this same
          # top-level attribute — so reclassifying the field user-facing would wrongly turn a
          # malformed-member (structural) failure into a user-facing one. Nested checks stay
          # dev-facing, exactly like subfields, so reject the combination (top-level fields only).
          raise ArgumentError, "user_facing: is not supported with a shape block (nested member checks are always dev-facing)" if user_facing && block

          reader_names = _resolve_reader_names(fields, as:, prefix:, readers:)
          # `readers: false` generates no reader, so it can neither be reserved-shadowing nor collide
          # with an existing reader — skip validation entirely so the escape hatch holds regardless of
          # declaration order (e.g. `expects :raw_id, as: :id` then `expects :id, on:, readers: false`).
          _validate_reader_names!(reader_names) if readers

          validations, metadata = _partition_field_options(fields, **)

          if on.present?
            raise ArgumentError, "a shape block is not supported with `on:`" if block

            return _expects_subfields(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                               reader_names:, **validations)
          end

          validations[:shape] = _build_shape(fields, validations:, &block) if block

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                        reader_names:, define_readers: true, user_facing:, **validations).tap do |configs|
            duplicated = internal_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.internal_field_configs += configs
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def exposes(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          sensitive: false,
          **,
          &block
        )
          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPOSURES.include?(field.to_s)
          end

          validations, metadata = _partition_field_options(fields, **)

          validations[:shape] = _build_shape(fields, validations:, &block) if block

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess: nil, sensitive:, metadata:, **validations).tap do |configs|
            duplicated = external_field_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.external_field_configs += configs
          end
        end

        def inspection_filter
          @__inspection_filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          _static_sensitive_fields
        end

        def _static_sensitive_fields
          (internal_field_configs + external_field_configs + subfield_configs).select { |c| c.sensitive == true }.map(&:field)
        end

        def _has_dynamic_sensitive_fields?
          @_has_dynamic_sensitive_fields ||= (internal_field_configs + external_field_configs + subfield_configs).any? do |config|
            config.sensitive.is_a?(Proc) || config.sensitive.is_a?(Symbol)
          end
        end

        def _resolve_sensitive_fields(action_instance)
          return _static_sensitive_fields unless _has_dynamic_sensitive_fields?

          (internal_field_configs + external_field_configs + subfield_configs).select do |config|
            _resolve_sensitive_value(config.sensitive, action_instance)
          end.map(&:field)
        end

        def _resolve_sensitive_value(sensitive, action_instance)
          case sensitive
          when true, false
            sensitive
          when Symbol
            !!action_instance.send(sensitive)
          when Proc
            !!action_instance.instance_exec(&sensitive)
          else
            !!sensitive
          end
        end

        def _build_instance_filter(action_instance)
          ActiveSupport::ParameterFilter.new(_resolve_sensitive_fields(action_instance))
        end

        # `on:` references a parent by its *reader* name, which may be an `as:`/`prefix:` alias — but
        # provided_data and the inspector's subfield filtering are keyed by the caller-facing *wire*
        # key. Translate an aliased top-level parent back to its wire key. Identity for non-aliased
        # parents (reader_as == field) and for names that match no top-level reader. Only top-level
        # parents are consulted: a nested/subfield parent can't be written through the single-level
        # mutation machinery and is rejected at declaration when combined with
        # default:/preprocess:/sensitive: (see ContractForSubfields#_expects_subfields), so it never
        # reaches the mutation or sensitive-filtering paths.
        def _wire_parent_key(on)
          config = internal_field_configs.find { |c| c.reader_as.to_s == on.to_s }
          config ? config.field : on.to_sym
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
        # When action_instance is provided, dynamic sensitive fields are resolved against that instance.
        def _context_slice(data:, direction: nil, action_instance: nil)
          filter = if action_instance && _has_dynamic_sensitive_fields?
                     _build_instance_filter(action_instance)
                   else
                     inspection_filter
                   end
          filter.filter(data.slice(*_declared_fields(direction)))
        end

        private

        # Map each declared field to the name of its generated reader. Without `as:`/`prefix:` the
        # reader is named for the wire key (identity). `as:` renames a single field's reader;
        # `prefix:` is sugar that prepends to every field's reader (literal concatenation, so the
        # caller supplies the separator). The wire key (`field`) stays canonical regardless.
        def _resolve_reader_names(fields, as:, prefix:, readers:)
          return fields.to_h { |f| [f, f] } if as.nil? && prefix.nil?

          raise ArgumentError, "`as:` and `prefix:` cannot be combined" if as && prefix
          raise ArgumentError, "`as:`/`prefix:` require a reader (incompatible with readers: false)" unless readers
          if fields.any? { |f| f.to_s.include?(".") }
            raise ArgumentError, "`as:`/`prefix:` are not supported for a dotted subfield key (it generates no reader)"
          end

          if as
            raise ArgumentError, "`as:` can only be provided when declaring a single field (use prefix: for several)" if fields.size > 1

            { fields.first => as.to_sym }
          else
            fields.to_h { |f| [f, :"#{prefix}#{f}"] }
          end
        end

        # Renamed readers must clear the same reserved-name bar as wire keys (identity readers are
        # already reserved-checked against their wire key in `expects`), and no two declarations may
        # resolve to the same reader name.
        def _validate_reader_names!(reader_names)
          reader_names.reject { |field, reader| field == reader }.each_value do |reader|
            raise ContractViolation::ReservedAttributeError, reader if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(reader.to_s)
          end

          # A collision is a *new* reader name already claimed by an existing config under a different
          # wire key. A same-wire-key clash is a genuine duplicate field, reported downstream with a
          # clearer DuplicateFieldError, so it's excluded here. Checking every new reader (not just
          # aliases) catches alias-vs-plain clashes in either declaration order — e.g.
          # `expects :bar, as: :foo` then `expects :foo`, which would otherwise silently clobber the
          # `bar` reader. Intra-call duplicates (distinct fields → same reader) are caught too.
          # Only configs that actually generated a reader can be collided with. A subfield declared
          # `readers: false` (the documented escape hatch) — or a dotted-key subfield — defines no
          # method, so its name stays free; consult the method table rather than every config so
          # those readerless declarations don't manufacture phantom collisions.
          existing = (internal_field_configs + subfield_configs)
                     .select { |c| method_defined?(c.reader_as) }
                     .to_h { |c| [c.reader_as, c.field] }
          collisions = reader_names.filter_map { |field, reader| reader if existing.key?(reader) && existing[reader] != field }
          collisions |= reader_names.values.tally.select { |_, count| count > 1 }.keys
          raise ArgumentError, "Reader name collision: #{collisions.uniq.join(', ')}" if collisions.any?
        end

        # `user_facing:` reclassifies a violation of this field from a dev-facing exception into a
        # user-facing failure (see Executor). Its value doubles as the surfaced message: `true` uses
        # the field's own validation message; a String overrides it; a Symbol names an action method
        # and a Proc computes it from the InboundValidationError — the full `error`/`fail!`/`fails_on`
        # handler shape. Anything else is a programmer error, so reject it at declaration.
        def _validate_user_facing!(user_facing)
          return if [false, true].include?(user_facing) || user_facing.is_a?(String) || user_facing.is_a?(Symbol) ||
                    Axn::Core::Flow::Handlers::Invoker.callable?(user_facing)

          raise ArgumentError,
                "user_facing: must be true, a String, a Symbol, or a Proc (got #{user_facing.inspect})"
        end

        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! ok?
          inspect default_error
          each_pair
          default_success
          action_name
          inputs
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
          prefixed
          inputs
        ].freeze

        KNOWN_VALIDATION_KEYS = Set.new(%i[
                                          absence acceptance comparison confirmation exclusion format
                                          inclusion length numericality presence uniqueness
                                          type model validate of shape
                                          if unless on message strict
                                        ]).freeze

        # Types for which a shape block is meaningless — the block describes the members of a
        # structured value (Array elements, Hash keys, or a class's readers), not a scalar.
        SHAPE_INCOMPATIBLE_TYPES = [String, Integer, Float, Numeric, TrueClass, FalseClass, Symbol, NilClass,
                                    Date, Time, DateTime,
                                    :boolean, :uuid, :params].freeze

        # Field-level options a shape member supports (beyond validations + metadata). Shape members
        # are validation/schema-only: they have no single value to default/preprocess, and the log
        # filter can't redact a per-element member, so default:/preprocess:/sensitive: are rejected
        # rather than silently dropped when converting to a ShapeConfig.
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil optional].freeze
        SHAPE_MEMBER_UNSUPPORTED_OPTIONS = %i[default preprocess sensitive].freeze

        # Parse a structured field's block into a `{ members: [...], container: <klass> }` validation
        # value. `container` lets ShapeValidator defer a type mismatch to TypeValidator (rather than
        # trying to extract members from the wrong kind of value).
        def _build_shape(fields, validations: nil, &)
          raise ArgumentError, "a shape block can only be declared on a single field" if fields.size > 1

          container = _shape_compatible_type!(validations)

          builder = ShapeBuilder.new
          builder.instance_exec(&)

          members = builder.declarations.map { |name, opts, subblock| _build_shape_member(name, opts, subblock) }

          { members:, container: }
        end

        # A member reuses the same option handling as a top-level field (optional/allow_blank/
        # default/etc. + validations + metadata), but yields a ShapeConfig and never a reader.
        def _build_shape_member(name, opts, subblock)
          unsupported = opts.keys & SHAPE_MEMBER_UNSUPPORTED_OPTIONS
          if unsupported.any?
            raise ArgumentError,
                  "shape member `#{name}` does not support #{unsupported.map { |k| "#{k}:" }.join('/')} " \
                  "(shape blocks declare validation/schema only)"
          end

          field_opts = opts.slice(*SHAPE_MEMBER_FIELD_OPTIONS)
          field_validations, metadata = _partition_field_options([name], **opts.except(*SHAPE_MEMBER_FIELD_OPTIONS))

          field_validations[:shape] = _build_shape([name], validations: field_validations, &subblock) if subblock

          config = _parse_field_configs(name, metadata:, **field_opts, **field_validations).first
          ShapeConfig.new(field: name, validations: config.validations, metadata: config.metadata)
        end

        # A shape block requires a single, structured type:. Mirrors the of: guard's strictness.
        # Returns the structured klass (Array, Hash, or a member-bearing class).
        def _shape_compatible_type!(validations)
          type = validations&.dig(:type)
          klass = type.is_a?(Hash) ? type[:klass] : type
          klasses = Array(klass)
          return klasses.first if klasses.size == 1 && SHAPE_INCOMPATIBLE_TYPES.exclude?(klasses.first)

          raise ArgumentError,
                "a shape block requires a single structured type: (Array, Hash, or a class) — got #{klasses.inspect}"
        end

        def _partition_field_options(fields, **options)
          metadata_keys = Axn.extension_config.registered_field_metadata_keys
          metadata = options.slice(*metadata_keys)
          validations = options.except(*metadata_keys)

          unknown = validations.keys.reject { |k| KNOWN_VALIDATION_KEYS.include?(k) }
          if unknown.any?
            raise ArgumentError,
                  "Unknown key(s) #{unknown.map(&:inspect).join(', ')} in field declaration. " \
                  "Not a recognized validation or registered field metadata key."
          end

          if metadata.present? && fields.size > 1
            raise ArgumentError,
                  "Field metadata (#{metadata.keys.join(', ')}) can only be provided when declaring a single field"
          end

          [validations, metadata]
        end

        # rubocop:disable Metrics/ParameterLists
        def _parse_field_configs(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          reader_names: {},
          define_readers: false,
          user_facing: false,
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            reader = reader_names[field] || field
            FieldConfig.new(field:, validations: parsed_validations, default:, preprocess:, sensitive:, metadata:, reader_as: reader,
                            user_facing:).tap do |config|
              if define_readers
                _define_field_reader(reader, field)
                _define_boolean_predicate_reader(reader) if Axn::Internal::FieldConfig.boolean?(config)
                _define_model_id_reader(reader, field, parsed_validations[:model]) if parsed_validations.key?(:model)
              end
            end
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # An auto-generated companion reader (boolean predicate, model `<field>_id`) defers to any
        # pre-existing method of the same name rather than clobbering it — but, unlike a silent skip,
        # leaves a debug-level breadcrumb so a surprising shadow is discoverable. Returns true when
        # the name is free (caller should define it), false when it's taken (already logged).
        def _reader_name_available?(name, kind:)
          return true unless method_defined?(name) || private_method_defined?(name)

          Axn.config.logger.debug { "[Axn] #{self.name || 'Action'}: skipping auto-generated #{kind} reader `#{name}` (already defined)" }
          false
        end

        # `model:` fields get a `<reader>_id` reader meaning "the primary key of the resolved
        # record", reading the raw id from the inbound context. The subfield contract defines the
        # same reader against an `on:` parent — both share `_define_model_id_reader_from`.
        def _define_model_id_reader(reader, source_field, model_options)
          by_primary_key = model_options.is_a?(Hash) && model_options[:finder] == :find
          _define_model_id_reader_from(reader:, source_field:, by_primary_key:) do |id_key|
            @__context.provided_data[id_key]
          end
        end

        # Defines the `<reader>_id` reader shared by the top-level and subfield `model:` contracts.
        # For the default (id-based `:find`) finder a directly-supplied, non-blank id IS the pk, so
        # it's returned without resolving the record; otherwise (a record was passed, the id was
        # blank, or a custom finder is in play) it reads the resolved — and memoized — record's `.id`,
        # so it never triggers a second lookup. A blank id is treated as absent (matching the
        # resolver/consistency check), and a missing record yields nil rather than the raw input —
        # which for a custom finder is a lookup token, not a primary key. `raw_reader` yields the raw
        # `<field>_id` value for the caller's context (top-level provided_data vs. the `on:` parent).
        def _define_model_id_reader_from(reader:, source_field:, by_primary_key:, &raw_reader)
          id_reader = :"#{reader}_id"
          return unless _reader_name_available?(id_reader, kind: "model id")

          id_key = :"#{source_field}_id"
          define_method(id_reader) do
            raw = instance_exec(id_key, &raw_reader)
            next raw if by_primary_key && !raw.nil? && !raw.to_s.strip.empty?

            record = public_send(reader)
            record.respond_to?(:id) ? record.id : nil
          end
        end

        def _define_field_reader(reader, source = reader)
          # Allow local access to explicitly-expected fields on the action instance.
          # NOTE: exposes fields are intentionally excluded — access those via result.field instead.
          # `reader` is the method name (may be aliased via as:/prefix:); `source` is the wire key
          # the value actually lives under in the inbound context.
          define_method(reader) { internal_context.public_send(source) }
        end

        def _define_boolean_predicate_reader(field)
          field_name = field.to_s
          return if field_name.end_with?("?") || field_name.include?(".")

          predicate_name = "#{field_name}?"
          return unless _reader_name_available?(predicate_name, kind: "boolean predicate")

          alias_method predicate_name, field
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

          if validations.key?(:of)
            declared_klasses = Array(validations.dig(:type, :klass))
            raise ArgumentError, "of: requires type: Array (got #{declared_klasses.inspect})" unless declared_klasses == [Array]

            validations[:of] = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
            raise ArgumentError, "of: must supply :klass" if validations[:of][:klass].nil?
          end

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
        def internal_context = @__internal_context ||= _build_context_facade(:inbound)
        def result = @__result ||= _build_context_facade(:outbound)

        # Resolved declared-inbound fields as a Hash (defaults/preprocess applied, model: fields
        # resolved to their record), keyed by wire key. Splat into a nested action to forward
        # inputs: `Child.call(**inputs, override: x)`. Reads through internal_context (not raw
        # provided_data) so a model: field supplied by `<field>_id` forwards the resolved record —
        # the record lives only in the reader. Fields whose resolved value is nil are omitted, so a
        # nested action still applies its own absent/default handling for them.
        def inputs
          self.class._declared_fields(:inbound).each_with_object({}) do |field, hash|
            value = internal_context.public_send(field)
            hash[field] = value unless value.nil?
          end
        end

        delegate :default_error, :default_success, to: :internal_context

        # Accepts:
        # - a single Axn::Result: forwards (result.declared_fields & own outbound declared fields)
        # - two positional arguments (key, value)
        # - a hash of key/value pairs
        def expose(*args, **kwargs)
          return _expose_from_result(args.first) if args.size == 1 && kwargs.empty? && args.first.is_a?(Axn::Result)

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

        # Forward the intersection of a nested result's declared exposures and this action's own
        # declared exposures. Reads declared fields (static contract) so it is safe on a failed
        # result — it forwards whatever the child managed to expose (nil for the rest) and never
        # inspects ok?/error or calls fail!. An empty intersection is always a wiring mistake.
        def _expose_from_result(source_result)
          forwardable = source_result.declared_fields & self.class._declared_fields(:outbound)

          if forwardable.empty?
            raise Axn::ContractViolation::NoMatchingExposures.new(
              declared: self.class._declared_fields(:outbound),
              exposed: source_result.declared_fields,
            )
          end

          forwardable.each do |field|
            @__context.exposed_data[field] = source_result.public_send(field)
          end
        end

        # Filtered inbound fields only (no additional context) - used by automatic logging and execution_context
        def inputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :inbound, action_instance: self)
        end

        # Filtered outbound fields only (no additional context) - used by automatic logging and execution_context
        def outputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :outbound, action_instance: self)
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
