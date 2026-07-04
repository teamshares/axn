# frozen_string_literal: true

require "date"
require "time"

module Axn
  module Reflection
    module Schema
      TYPE_MAP = {
        String => "string",
        Symbol => "string",
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
      # is intentionally NOT represented in the schema: a dotted parent (`on: "address.billing"`),
      # a subfield-of-a-subfield (`on: :some_subfield`), or a dotted subfield NAME
      # (`expects "bar.baz", on: :foo`) validates and reads fine at runtime but is omitted here.
      # Deferred until an adapter (axn-mcp PRO-2844 / axn-ruby_llm PRO-2845)
      # actually needs deep tool-input schemas — at which point the nesting can be built as a full
      # `on:`-path walk informed by the real consumer. See those tickets.
      def build_input(field_configs, subfield_configs = [])
        properties = {}
        required = []

        # Group ALL subfields for the parent-requiredness decision below — runtime's
        # validate_subfields_contract! validates EVERY declared subfield (incl. dotted deep paths,
        # subfield-of-subfield chains, and dotted `on:` parents), so an omitted top-level root fails
        # exactly as it would for a shallow subfield. Every subfield is attributed to the top-level
        # field its `on:` chain ULTIMATELY roots at — a dotted parent (`on: "address.billing"`)
        # rolls up to :address, and a subfield whose `on:` points at another subfield (rather than a
        # top-level field) rolls up through that subfield's own `on:` to whatever top-level field it
        # ultimately reads from. Property NESTING, though, is built only from DIRECT single-level
        # children — those whose `on:` names the parent's reader exactly and whose own field name
        # isn't dotted (see KNOWN LIMITATION above; deferred to PRO-2844/PRO-2845) — so a deep
        # descendant's shape is omitted, but its root's requiredness must still match runtime.
        field_readers = field_configs.map(&:reader_as)
        subfields_by_root = subfield_configs.group_by { |c| top_level_root_reader(c, subfield_configs, field_readers) }

        field_configs.each do |config|
          next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          if config.validations[:model]
            build_model_property(config, properties, required)
          else
            prop = build_property(config)
            all_nested = subfields_by_root[config.reader_as]
            # Direct shallow children: `on:` names THIS field's reader exactly (not a dotted path, and
            # not another subfield), and the child's own field name isn't dotted. Everything else that
            # rolls up to this root — a dotted `on:` path, an `on:` pointing at another subfield, or a
            # dotted field name — is a deep descendant: still counted for requiredness below, but its
            # shape is omitted from the nested properties.
            shallow_nested = all_nested&.select { |c| c.on.to_sym == config.reader_as && !c.field.to_s.include?(".") }
            apply_nested_subfields!(prop, config, shallow_nested)

            properties[config.field] = prop.compact

            if all_nested.present?
              required << config.field.to_s if subfield_root_required?(config, all_nested, shallow_nested, prop)
            else
              required << config.field.to_s unless optional_for_schema?(config)
            end
          end
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Whether a top-level root that has nested subfields must be listed in the input schema's
      # `required`. prop[:required] holds only the SHALLOW required children (apply_nested_subfields!
      # built it from shallow_nested). A deep descendant (dotted `on:` path, nested subfield, or dotted
      # field name) is omitted from the schema SHAPE but still validated at runtime, so it's counted
      # here too — else a root with only deep (or only optional) descendants would be wrongly relaxed.
      def subfield_root_required?(config, all_nested, shallow_nested, prop)
        deep_nested = all_nested - (shallow_nested || [])
        shallow_has_required_child = prop[:required].is_a?(Array) && prop[:required].any?
        deep_has_required_child = deep_nested.any? { |c| !optional_for_schema?(c, subfield: true) }
        parent_has_required_child = shallow_has_required_child || deep_has_required_child
        # Omitting the root is safe only if something materializes it before subfield validation:
        # a top-level default on the root, or a truthy default on any descendant subfield.
        parent_materialized = default?(config) || all_nested.any? { |sc| !!sc.default }
        # A required child is fine to omit-with-the-root only if the root's own literal Hash default
        # would actually SATISFY that child at runtime (Axn applies the default, then validates) —
        # not merely supply its key (see default_covers_required? for why). Coverage is checked
        # against SHALLOW required children only; a deep required child (dotted path/nested subfield)
        # can't be verified that way, so it keeps the root required.
        covered = !parent_has_required_child ||
                  (!deep_has_required_child && default_covers_required?(config.default, shallow_nested))
        !(parent_materialized && covered)
      end

      # The top-level field reader a subfield's on:-path ultimately roots at. `on:` may be a dotted path
      # ("address.billing" → root :address) or point at another subfield's reader (walk up to its parent).
      # Returns nil if the chain never reaches a top-level reader (malformed contract) — such a subfield is
      # then attributed to no field and omitted, matching today's behavior. Cycle-guarded.
      def top_level_root_reader(config, subfield_configs, field_readers)
        seen = []
        current = config
        loop do
          root_segment = current.on.to_s.split(".").first.to_sym
          return root_segment if field_readers.include?(root_segment)
          return nil if seen.include?(root_segment)

          seen << root_segment
          parent = subfield_configs.find { |c| c.reader_as == root_segment }
          return nil unless parent

          current = parent
        end
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

      # Deep-copy a reflected literal (a default: value or an inclusion enum member) AND normalize any
      # leaf whose JSON wire form differs from its Ruby form — Time/DateTime/Date → iso8601 String,
      # Symbol → String, non-Integer/Float Numeric (BigDecimal/Rational) → Float — so the emitted
      # `default`/`enum` matches the property's advertised JSON type (mirrors Values.serialize_value).
      # Mutable String leaves are duped so a consumer mutating the returned schema can't reach the
      # stored contract; immutable scalars are shared.
      def normalize_schema_literal(value)
        case value
        when Hash then value.transform_values { |v| normalize_schema_literal(v) }
        when Array then value.map { |v| normalize_schema_literal(v) }
        when String then value.dup
        when Symbol then value.to_s
        when Time, DateTime, Date then value.iso8601
        when Numeric
          # Integer/Float are already JSON-native — leave them as-is. Any other Numeric
          # (BigDecimal, Rational, …) has no JSON representation, so render it as a JSON number
          # (Float); a non-real Numeric (Complex) can't become one, so fall back to its String form.
          return value if value.is_a?(Integer) || value.is_a?(Float)

          begin
            Float(value)
          rescue ArgumentError, TypeError, RangeError
            value.to_s
          end
        else value
        end
      end

      # Build the `enum:` member list for an inclusion validator's declared `in:`/`within:` set.
      # `nullable` (nil_allowed?) is the runtime truth: when false, an explicit nil is REJECTED even
      # if the declared set happens to list it (Axn's auto presence validator still fires without
      # `presence: false`/`allow_nil`) — so a literal `nil` member must be dropped from the enum to
      # match. When true, add `nil` only if it isn't already a member, to avoid a duplicate.
      # `blank_tolerant` mirrors `allow_blank: true` specifically on the inclusion validator —
      # ActiveModel skips the inclusion check entirely for a blank value, so e.g. `status: ""` is
      # accepted at runtime even though "" isn't literally in the declared set. Represent that by also
      # permitting the empty string, but only for a string-valued enum (a blank numeric/symbol input
      # isn't "") and only when it isn't already a member.
      def enum_for_inclusion(enum_values, nullable:, blank_tolerant:)
        members = normalize_schema_literal(enum_values)
        members = members.compact unless nullable
        members += [nil] if nullable && !members.include?(nil)
        members += [""] if blank_tolerant && members.any? { |m| m.is_a?(String) } && !members.include?("")
        members
      end

      # Whether `allow_blank: true` is set specifically on this field's inclusion validator — a
      # narrower check than nil_allowed?/nullable (which reflects nil-tolerance across ALL of the
      # field's validators combined). Only the inclusion validator's own allow_blank determines
      # whether "" should join its declared enum (see enum_for_inclusion).
      def blank_tolerant_inclusion?(config)
        inclusion = config.validations[:inclusion]
        inclusion.is_a?(Hash) && inclusion[:allow_blank] == true
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
          # The default is a value stored directly on the contract's FieldConfig — normalize AND
          # deep-copy it via normalize_schema_literal so (a) a caller mutating the returned schema
          # (e.g. `schema[:properties][:opts][:default][:b] = 2`, or mutating a String default in
          # place via `upcase!`) can't reach back into the runtime contract, and (b) a leaf whose JSON
          # wire form differs from its Ruby form (Time/DateTime/Date, Symbol, BigDecimal/Rational) is
          # rendered in that wire form, matching the property's advertised `type`/`format`. Immutable
          # scalar leaves (Integer/Float/true/false/nil) are shared, not copied.
          #
          # For a SUBFIELD, only a truthy default is ever applied at runtime
          # (`Executor#apply_defaults_for_subfields!` does `next unless config.default`), so a
          # falsey `default: false` subfield must not advertise a `default:` the runtime never
          # applies. Top-level fields are unaffected — their defaults are applied by key-presence.
          emit_default = subfield ? !!config.default : true
          prop[:default] = normalize_schema_literal(config.default) if emit_default
        end

        if (inclusion = config.validations[:inclusion])
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          # Same reasoning as default: above — `enum_values` here is the actual array stored in
          # the contract's validations hash (`config.validations[:inclusion][:in]`), so it (and any
          # mutable/non-JSON-native elements within it, e.g. String members or a Symbol member) must
          # be deep-copied and normalized rather than shared with the returned schema.
          prop[:enum] = enum_for_inclusion(enum_values, nullable:, blank_tolerant: blank_tolerant_inclusion?(config)) if enum_values.is_a?(Array)
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

      # A parent's own literal Hash default "covers" its required children only when, for EVERY required
      # shallow child, the defaulted value would actually satisfy that child at runtime (Axn applies the
      # default, THEN validates). A present-but-nil / wrong-type / blank-under-presence value does NOT
      # count — the parent stays required. We only vouch for children whose constraints are cheaply and
      # fully checkable here (a scalar `type:` plus presence); a child with ANY other validator
      # (inclusion/exclusion/format/numericality/length/model/of/shape/custom) could still reject a
      # type-correct value, so we stay conservative and treat it as NOT covered (parent required) —
      # accepting that this may over-require a parent whose valid default would actually pass (the safe
      # direction: the client sends a field it could technically omit, rather than being told it's optional
      # when the action rejects omission). A Proc default (or any non-Hash default) can't be inspected
      # here, so it never counts as covering either.
      def default_covers_required?(default_value, shallow_nested)
        return false unless default_value.is_a?(Hash)

        indiff = default_value.transform_keys(&:to_s)
        required_children = Array(shallow_nested).reject { |c| optional_for_schema?(c, subfield: true) }
        required_children.all? { |child| default_satisfies_child?(indiff, child) }
      end

      def default_satisfies_child?(indiff_default, child)
        return false if child.validations[:model] # model subfield uses <field>_id semantics — don't vouch

        key = child.field.to_s
        return false unless indiff_default.key?(key)

        value = indiff_default[key]
        return false if value.nil?

        # Only vouch when the child's constraints are limited to type: (+ presence).
        return false unless (child.validations.keys - %i[type presence]).empty?
        # Presence (explicit true, or Axn's implicit default) rejects a blank value.
        return false if child.validations[:presence] && _blank_for_presence?(value)

        type_opt = child.validations[:type]
        return true unless type_opt # presence-only child already satisfied by the non-blank value above

        klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
        Array(klass).any? { |k| _value_matches_type?(value, k) }
      end

      def _blank_for_presence?(value)
        return true if value == false

        value.respond_to?(:empty?) && value.empty?
      end

      def _value_matches_type?(value, klass)
        case klass
        when :boolean then [true, false].include?(value)
        when :uuid then value.is_a?(String)
        when :params then value.is_a?(Hash) || (defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters))
        else klass.is_a?(Class) && value.is_a?(klass)
        end
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
        # exclusion accepts nil when nil is NOT in the excluded set; inclusion accepts nil only
        # when nil IS an explicit member of the included set. A dynamic set (Proc) is uninspectable
        # here, so membership returns nil and the field stays conservatively required.
        return true if key == :exclusion && set_includes_nil?(opt) == false
        return true if key == :inclusion && set_includes_nil?(opt) == true

        false
      end

      # nil = can't tell (no concrete collection); true/false = nil's membership in the in:/within: set.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition (tri-state: nil is a meaningful "unknown", not "false")
      def set_includes_nil?(opt)
        return nil unless opt.is_a?(Hash)

        collection = opt[:in] || opt[:within]
        return nil unless collection.respond_to?(:include?)

        collection.include?(nil)
      rescue StandardError
        nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

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
