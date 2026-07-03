# frozen_string_literal: true

require "date"

module Axn
  module Reflection
    module Schema
      TYPE_MAP = {
        String => "string",
        Integer => "integer",
        Float => "number",
        Numeric => "number",
        Hash => "object",
        Array => "array",
        TrueClass => "boolean",
        FalseClass => "boolean",
        Date => "string",
        DateTime => "string",
        Time => "string",
      }.freeze

      FORMAT_MAP = {
        Date => "date",
        DateTime => "date-time",
        Time => "date-time",
      }.freeze

      EXCLUDED_FROM_INPUT_SCHEMA = %i[ambient_context].freeze

      module_function

      # KNOWN LIMITATION: only single-level subfields are nested — those whose `on:` names a
      # top-level field's reader (`on: :address`, incl. an `as:`/`prefix:` alias). Deeper nesting
      # is intentionally NOT represented in the schema: a dotted parent (`on: "address.billing"`)
      # or a subfield-of-a-subfield (`on: :some_subfield`) validates and reads fine at runtime but
      # is omitted here. Deferred until an adapter (axn-mcp PRO-2844 / axn-ruby_llm PRO-2845)
      # actually needs deep tool-input schemas — at which point the nesting can be built as a full
      # `on:`-path walk informed by the real consumer. See those tickets.
      def build_input(field_configs, subfield_configs = [])
        properties = {}
        required = []

        subfields_by_parent = subfield_configs.group_by { |c| c.on.to_sym }

        field_configs.each do |config|
          next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          if config.validations[:model]
            build_model_property(config, properties, required)
          else
            prop = build_property(config)
            nested = subfields_by_parent[config.reader_as]
            apply_nested_subfields!(prop, config, nested)

            properties[config.field] = prop.compact

            if nested.present?
              parent_has_required_child = prop[:required].is_a?(Array) && prop[:required].any?
              # Omitting the parent is safe only if something materializes it before subfield validation:
              # a top-level default on the parent, or a truthy default on a subfield (apply_defaults_for_subfields!).
              parent_materialized = default?(config) || nested.any? { |sc| !!sc.default }
              # A required child is fine to omit-with-the-parent if the parent's own literal Hash
              # default already supplies that child's key (runtime applies the default before
              # subfield validation, so the key is present even though the caller never set it).
              covered = !parent_has_required_child || default_covers_required?(config.default, prop[:required])
              required << config.field.to_s unless parent_materialized && covered
            else
              required << config.field.to_s unless optional_for_schema?(config)
            end
          end
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Mutates `prop` in place to nest `nested_subfields` (if any) as `prop[:properties]`/
      # `prop[:required]`. Forces the parent to `type: object` since it now has structure — never
      # nullable, even when allow_nil/allow_blank: a nil parent can't yield its subfields at
      # runtime (validate_subfields_contract! raises), so `null` must not be advertised here.
      def apply_nested_subfields!(prop, _config, nested_subfields)
        return if nested_subfields.blank?

        prop[:type] = "object"
        prop.delete(:format)
        prop[:properties] ||= {}
        prop[:required] ||= []

        nested_subfields.each do |subconfig|
          if subconfig.validations[:model]
            id_field, subprop = model_id_property(subconfig)
            # A user may declare an explicit nested `<field>_id` subfield before the `model:`
            # subfield (mirrors build_model_property's top-level handling) — don't clobber the
            # caller's already-built property with the generic model-generated one.
            prop[:properties][id_field] ||= subprop
            prop[:required] << id_field.to_s unless optional_for_schema?(subconfig, subfield: true)
          else
            subprop = build_property(subconfig, subfield: true)
            prop[:properties][subconfig.field] = subprop
            prop[:required] << subconfig.field.to_s unless optional_for_schema?(subconfig, subfield: true)
          end
        end

        prop[:required] = prop[:required].uniq
        prop[:required] = nil if prop[:required].empty?
      end

      def build_output(field_configs)
        properties = {}
        required = []

        field_configs.each do |config|
          prop = build_property(config, for_output: true)
          properties[config.field] = prop.compact
          required << config.field.to_s unless optional_for_schema?(config, for_output: true)
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Recursively copy a reflected JSON-ish value so a consumer can't mutate the stored contract
      # through the returned schema. Dups Hash/Array structure and mutable String leaves; shares
      # immutable leaves (Integer/Float/Symbol/true/false/nil).
      def deep_copy_value(value)
        case value
        when Hash then value.transform_values { |v| deep_copy_value(v) }
        when Array then value.map { |v| deep_copy_value(v) }
        when String then value.dup
        else value
        end
      end

      def build_property(config, for_output: false, subfield: false)
        prop = {}
        prop[:description] = config.description if config.description

        type_info = json_type_for(config.validations, for_output:)
        nullable = nil_allowed?(config)
        if type_info[:anyOf]
          prop[:anyOf] = nullable ? type_info[:anyOf] + [{ type: "null" }] : type_info[:anyOf]
        elsif type_info[:type]
          prop[:type] = nullable ? [type_info[:type], "null"] : type_info[:type]
          prop[:format] = type_info[:format] if type_info[:format]
        end

        if config.respond_to?(:default) && !config.default.nil? && !config.default.is_a?(Proc)
          # The default is a value stored directly on the contract's FieldConfig — deep-copy it so
          # a caller mutating the returned schema (e.g. `schema[:properties][:opts][:default][:b] = 2`,
          # or mutating a String default in place via `upcase!`) can't reach back into the runtime
          # contract. Immutable leaves (Integer/Float/Symbol/true/false/nil) are shared, not copied.
          #
          # For a SUBFIELD, only a truthy default is ever applied at runtime
          # (`Executor#apply_defaults_for_subfields!` does `next unless config.default`), so a
          # falsey `default: false` subfield must not advertise a `default:` the runtime never
          # applies. Top-level fields are unaffected — their defaults are applied by key-presence.
          emit_default = subfield ? !!config.default : true
          prop[:default] = deep_copy_value(config.default) if emit_default
        end

        if (inclusion = config.validations[:inclusion])
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          if enum_values.is_a?(Array)
            # Same reasoning as default: above — `enum_values` here is the actual array stored in
            # the contract's validations hash (`config.validations[:inclusion][:in]`), so it (and
            # any mutable elements within it, e.g. String members) must be deep-copied rather than
            # shared with the returned schema.
            prop[:enum] = deep_copy_value(nullable ? enum_values + [nil] : enum_values)
          end
        end

        apply_structured_schema!(prop, config, for_output:)

        prop
      end

      # Combine of: (bare element baseline) and shape: (typed member contracts) into
      # items:/properties: schema. Precedence: shape: enriches/overrides of: baseline.
      def apply_structured_schema!(prop, config, for_output:)
        of    = config.validations[:of]
        shape = config.validations[:shape]
        return unless of || shape

        if Array(prop[:type]).include?("array")
          items = of ? items_schema_for(of, for_output:) : {}
          if shape
            member_props, required = member_properties(shape[:members], for_output:)
            base_props = items[:properties] || {}
            items = items.merge(type: "object", properties: base_props.merge(member_props))
            items[:required] = required unless required.empty?
          end
          prop[:items] = items unless items.empty?
        elsif shape
          # Hash / class field — shape: members are the object's own properties. A shaped
          # object field IS an object, even when the field's declared type: (e.g. a
          # Data.define subclass) isn't in TYPE_MAP and json_type_for fell back to "string".
          prop[:type] = nil_allowed?(config) ? %w[object null] : "object"
          prop.delete(:format)
          # If the field type is a Data.define subclass, use its members as the bare
          # baseline so unannotated members still appear (same enrich logic as of:).
          member_props, required = member_properties(shape[:members], for_output:)
          type_klass = config.validations.dig(:type, :klass)
          base_props = type_klass.is_a?(Class) && type_klass < Data ? type_klass.members.to_h { |m| [m, {}] } : {}
          prop[:properties] = base_props.merge(member_props)
          prop[:required] = required unless required.empty?
        end
      end

      # Build a JSON Schema items: value from the of: validation hash.
      def items_schema_for(of_validations, for_output: false)
        klasses = Array(of_validations[:klass])
        if klasses.size == 1
          single_items_schema(klasses.first, for_output:)
        else
          { anyOf: klasses.map { |k| single_items_schema(k, for_output:) } }
        end
      end

      def single_items_schema(klass, for_output: false)
        if klass.is_a?(Class) && klass < Data
          # Data.define subclass → object with named (but untyped) properties as baseline
          { type: "object", properties: klass.members.to_h { |m| [m, {}] } }
        else
          json_type_for({ type: klass }, for_output:)
        end
      end

      # Build properties/required from a shape: block's members. Recurses for nested shape/of.
      def member_properties(members, for_output:)
        props = {}
        required = []
        members.each do |m|
          props[m.field] = build_property(m, for_output:).compact
          required << m.field.to_s unless optional_for_schema?(m, for_output:)
        end
        [props, required]
      end

      # Returns [id_field_symbol, prop_hash] for a model: config.
      def model_id_property(config)
        model_opts = config.validations[:model]
        klass = model_opts[:klass]
        klass_name = klass.is_a?(Class) ? klass.name : klass.to_s
        id_field = :"#{config.field}_id"
        # No type constraint: `find` (and custom finders) accept any nonblank PK token — integer,
        # UUID, or string PKs are all valid — and inferring the real PK type would require a DB/schema
        # load (not allowed from reflection). The description carries the "record id" semantics.
        prop = { description: config.description || "ID of the #{klass_name} record" }
        [id_field, prop.compact]
      end

      def build_model_property(config, properties, required)
        id_field, prop = model_id_property(config)
        # A user may declare an explicit `<field>_id` field before the `model:` field (the runtime's
        # generated model-id reader then defers to it, per `_reader_name_available?`) — don't clobber
        # the caller's already-built property, and don't double-add to `required`.
        properties[id_field] ||= prop
        required << id_field.to_s unless required.include?(id_field.to_s) || optional_for_schema?(config)
      end

      def single_type_for(klass, for_output:)
        return { type: "boolean" } if klass == :boolean
        return { type: "string", format: "uuid" } if klass == :uuid
        return { type: "object" } if klass == :params

        if TYPE_MAP.key?(klass)
          result = { type: TYPE_MAP[klass] }
          result[:format] = FORMAT_MAP[klass] if FORMAT_MAP.key?(klass)
          return result
        end

        return { type: "object" } if for_output

        { type: "string" }
      end

      def json_type_for(validations, for_output: false)
        if validations[:type]
          type_opt = validations[:type]
          klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
          type_hashes = Array(klass).map { |k| single_type_for(k, for_output:) }.uniq
          return type_hashes.first if type_hashes.size == 1

          return { anyOf: type_hashes }
        end

        if validations[:inclusion]
          inclusion = validations[:inclusion]
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          if enum_values.is_a?(Array) && enum_values.any?
            types = enum_values.map { |v| enum_scalar_type(v) }.uniq
            return { type: types.first } if types.size == 1 && types.first

            # mixed (or unrecognized) value types → let `enum` constrain; emit no `type`
            return {}
          end
        end

        if validations[:numericality]
          numericality = validations[:numericality]
          return { type: "integer" } if numericality.is_a?(Hash) && numericality[:only_integer]

          return { type: "number" }
        end

        {}
      end

      def enum_scalar_type(value)
        return "string" if value.is_a?(String)
        return "integer" if value.is_a?(Integer)
        return "number" if value.is_a?(Float)

        nil
      end

      def optional?(config)
        Axn::Internal::FieldConfig.optional?(config)
      end

      # A defaulted field is client-omittable (Axn applies inbound defaults before validation),
      # so it must not be listed in an input schema's `required` — even when not `optional:`/
      # `allow_blank:`. Output (`exposes`) requiredness is unaffected: see build_output.
      def default?(config)
        config.respond_to?(:default) && !config.default.nil?
      end

      # True when the parent's own literal Hash default already provides every required child key
      # (so omitting the parent still satisfies subfield validation at runtime). A Proc default (or
      # any non-Hash default) can't be inspected here, so it never counts as covering — the parent
      # stays required in that case.
      def default_covers_required?(default_value, required_child_keys)
        return false unless default_value.is_a?(Hash)

        keys = default_value.keys.map(&:to_s)
        Array(required_child_keys).all? { |k| keys.include?(k.to_s) }
      end

      # The contract accepts an omitted/nil value for this field iff nothing rejects nil: no presence
      # requirement, and every validator that would run allows nil/blank. A single validator's
      # allow_nil does NOT make the field nullable if another (presence, type, …) still rejects nil.
      #
      # An entry is nil-tolerant if it's a disabled validator (`opt == false`), `absence` (nil is
      # always "absent", regardless of options), `acceptance` unless explicitly opted out via
      # `allow_nil: false` (ActiveModel's acceptance validator is allow_nil by default), or a Hash
      # that allows nil/blank. Any other active validator — including a BARE `true` (e.g.
      # `numericality: true`) — rejects nil: a bare ActiveModel validator does not tolerate nil just
      # because it isn't a Hash of options, so `presence: false` alongside a bare active validator
      # must not wrongly relax the field (Bug KK).
      def nil_accepted?(config)
        v = config.validations
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end

      def nil_tolerant_validation?(key, opt)
        return true if opt == false                                 # disabled validator (e.g. presence: false)
        return true if opt.is_a?(Hash) && (opt[:allow_nil] || opt[:allow_blank])
        return true if key == :absence                              # nil is always "absent"
        # acceptance is allow_nil by default; only nil-rejecting when explicitly `allow_nil: false`
        return true if key == :acceptance && !(opt.is_a?(Hash) && opt[:allow_nil] == false)

        false
      end

      # A field is optional in the schema (client may omit it) iff it has a default, or no validation
      # rejects a nil/omitted value. A typed field with neither (e.g. type: :boolean) is required —
      # TypeValidator rejects nil. (This subsumes the earlier default?-based check.)
      #
      # `subfield:` narrows what counts as a "usable" default: `Executor#apply_defaults_for_subfields!`
      # only applies a subfield's default when it's truthy (`next unless config.default`), so a falsey
      # subfield default (`false`/`nil`) is never actually applied and must NOT make the field optional
      # here. Top-level defaults are applied by key-presence, so `default?` (non-nil) is correct there.
      def optional_for_schema?(config, for_output: false, subfield: false)
        has_usable_default = subfield ? !!config.default : default?(config)
        return true if !for_output && has_usable_default

        nil_accepted?(config)
      end

      # Whether a field's validations, taken together, permit nil/blank. Used both to decide
      # schema-optionality (input) and to add "null" to the emitted JSON Schema type (both input
      # and output — an explicit nil is accepted at runtime regardless of direction). A lone
      # validator's allow_nil: does NOT count if another validator (e.g. presence, or the type
      # validator itself) still rejects nil.
      def nil_allowed?(config)
        nil_accepted?(config)
      end
    end
  end
end
