# frozen_string_literal: true

require "date"
require "time"

module Axn
  module Reflection
    # Builds JSON Schema (input/output) from an Axn's declared contract. Read-only, off the execution
    # path — it inspects declared field configs, never runs the action or its validators.
    #
    # REQUIREDNESS IS DERIVED FROM DECLARED SIGNALS, NOT BY VALIDATING.
    # A field is omittable (absent from `required`) when a declared signal says so — a usable default,
    # or a nil/blank-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`/`presence: false`).
    # We deliberately do NOT run the field's validators against its default to confirm the omitted call
    # would actually pass; that duplicate-validation pass was expensive and fragile. The tradeoff is a
    # few documented divergences from runtime, all narrow:
    #   * a non-blank but otherwise-invalid default (`type: String, default: 123`; `type: :uuid,
    #     default: "nope"`) is reflected as optional though the omitted call fails at runtime;
    #   * a required deep subfield (dotted `on:`/name, subfield-of-subfield) under a nil-tolerant parent
    #     doesn't force the parent required, so the parent may reflect as optional though runtime needs it.
    # The safe direction (schema stricter than runtime) never causes failed calls; the unsafe cases above
    # only arise from self-contradictory contracts and surface as a normal, recoverable validation error.
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

      # KNOWN LIMITATION: only single-level subfields are represented — those whose `on:` names a
      # top-level field's reader (`on: :address`, incl. an `as:`/`prefix:` alias) with a non-dotted
      # field name. Deeper nesting (a dotted `on:` path like `on: "address.billing"`, a subfield of a
      # subfield, or a dotted field name like `expects "bar.baz", on: :foo`) validates at runtime but is
      # omitted from the schema, deferred until an adapter needs deep tool-input schemas (axn-mcp
      # PRO-2844 / axn-ruby_llm PRO-2845).
      def build_input(field_configs, subfield_configs = [])
        properties = {}
        required = []

        subfields_by_parent = subfield_configs.group_by { |c| c.on.to_sym }

        field_configs.each do |config|
          next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          if config.validations[:model]
            build_model_property(config, properties, required, field_configs)
          else
            prop = build_property(config)
            shallow = shallow_subfields(subfields_by_parent[config.reader_as], config)
            apply_nested_subfields!(prop, config, shallow)

            properties[config.field] = prop.compact
            required << config.field.to_s unless field_optional?(config, shallow)
          end
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Direct single-level children of `config`: `on:` names its reader exactly (not a dotted path or
      # another subfield) and the child's own field name isn't dotted. Deeper descendants are omitted.
      def shallow_subfields(nested, config)
        Array(nested).select { |c| c.on.to_sym == config.reader_as && !c.field.to_s.include?(".") }
      end

      # Whether a field's declared type can be represented as a JSON object (so its subfields can nest
      # as object properties): Hash, `:params`, or untyped. A `type: Array` (or other non-object) parent
      # is not — its subfields are extracted differently at runtime and have no object-property shape.
      def object_shaped?(config)
        type_opt = config.validations[:type]
        return true unless type_opt

        klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
        Array(klass).any? { |k| [Hash, :params].include?(k) }
      end

      # Whether a shaped field's value serializes to a member-keyed JSON object (so advertising `object` +
      # the shape's properties on OUTPUT matches serialize_exposed). Only asserted for types with a
      # language-guaranteed member-keyed serialization: `:params`, an untyped shape (caller supplies a
      # Hash), Hash, Data, or Struct. Any other class is statically unknowable — its own `to_h`/`as_json`
      # (which Values.serialize_value follows, as_json first) may emit a scalar/array/differently-keyed
      # hash, and a reader-only class with neither serializes to a String (to_s) / instance-variable dump
      # (Object#as_json) — so those stay untyped on output rather than promise an object.
      def shape_serializes_to_object?(config)
        type_klass = config.validations.dig(:type, :klass)
        return true if type_klass.nil?

        Array(type_klass).all? do |k|
          k == :params || (k.is_a?(Class) && (k <= Hash || k <= Data || k <= Struct))
        end
      end

      # A field is absent from `required` when a declared signal makes it omittable.
      def field_optional?(config, shallow_subfields)
        shallow = Array(shallow_subfields)
        # A required shallow subfield can never be satisfied by an omitted parent: runtime runs subfield
        # validation after top-level, so a nil/absent parent strands the child and the call fails.
        has_required_child = shallow.any? { |c| !optional_for_schema?(c, subfield: true) }

        # A usable default on the PARENT materializes it (with its declared contents) before validation,
        # so it may always be omitted — its own default, not its subfields, decides. (A default whose
        # contents fail a child's validators is a separate, narrow divergence handled by usable_default?.)
        return true if usable_default?(config, subfield: false)

        # The parent's own nil-tolerance (optional:/allow_nil:) only makes it omittable when no required
        # child would be stranded — so it must be checked AFTER the required-child test, not ahead of it.
        return true if nil_accepted?(config) && !has_required_child

        # No parent-level omission signal: the parent is omittable only if runtime can synthesize a
        # COMPLETE parent from subfield defaults — at least one shallow subfield supplies a value and none
        # is required (a required child has no default and can't be synthesized). This synthesis only
        # rescues an OBJECT-shaped parent: `apply_defaults_for_subfields!` injects `{}`, which satisfies a
        # Hash/`:params`/untyped parent but not a non-object one (`type: Array`, a typed class) whose
        # top-level type validator rejects the `{}`.
        return false unless object_shaped?(config)

        shallow.any? { |c| usable_default?(c, subfield: true) } && !has_required_child
      end

      # Optional (client may omit) iff a usable default exists, or — with no usable default — the
      # validators tolerate a nil/omitted value. Top-level `exposes` requiredness is NOT decided here:
      # `build_output` marks every top-level exposed key required directly (the serializer always emits
      # them). This method reaches a `for_output` config only for a nested shape member, which is
      # serialized from the actual value and so honors its own `optional:`/`allow_nil:`/`default:`.
      def optional_for_schema?(config, subfield: false)
        return true if usable_default?(config, subfield:)

        nil_accepted?(config)
      end

      # A default lets the client omit the field (Axn applies it before validation). We judge usability
      # by declared SHAPE only — present, not a Proc — never by running the field's validators. A Proc
      # default is uninspectable here. For a subfield, only a truthy default is applied at runtime
      # (`next unless config.default`), so a falsey subfield default never counts.
      #
      # An empty literal default (`{}`/`""`/`[]`) makes the field omittable only when no active presence
      # validator would reject the synthesized blank: a non-optional field carries `presence: true` and so
      # stays required, but a `presence: false` field (or a type like `:params` that carries no presence)
      # accepts the blank and is optional. (A blank rejected by some OTHER validator — e.g. length — is a
      # self-contradictory contract: the same accepted divergence as a non-blank invalid default, where
      # the schema reflects optional though the omitted call fails at runtime.)
      #
      # The emptiness check is limited to literal containers (Hash/Array/String): reflection must stay
      # side-effect-free, and calling `empty?` on an arbitrary default (e.g. an ActiveRecord::Relation or
      # other lazy collection) could issue a query or run user code. A non-literal default is present.
      def usable_default?(config, subfield:)
        return false unless config.respond_to?(:default)

        value = config.default
        return false if value.nil? || value.is_a?(Proc)
        return false if literal_container?(value) && value.empty? && presence_rejects_blank?(config)

        subfield ? !!value : true
      end

      # Whether an active presence validator would reject a blank value, so a blank default can't relax
      # the field. `presence: true` rejects blank; absent/`presence: false` doesn't; and
      # `presence: { allow_blank: true }` skips (accepts) blank. (`allow_nil` alone doesn't help a
      # non-nil blank like ""/{}/[].)
      def presence_rejects_blank?(config)
        presence = config.validations[:presence]
        return false unless presence

        !(presence.is_a?(Hash) && presence[:allow_blank])
      end

      # A built-in literal container whose `empty?` is a pure in-memory check. Uses instance_of? (exact
      # class), not is_a?: an Array/Hash/String SUBCLASS could override `empty?` with user code.
      def literal_container?(value)
        value.instance_of?(Hash) || value.instance_of?(Array) || value.instance_of?(String)
      end

      # Mutates `prop` to nest `nested_subfields` as `prop[:properties]`/`prop[:required]`. Forces the
      # parent to `type: object` (it now has structure) and never nullable: a nil parent can't yield its
      # subfields at runtime, so `null` must not be advertised. Only applies to an object-shaped parent
      # (Hash/`:params`/untyped) — a non-object parent (e.g. `type: Array`) keeps its declared type and
      # its subfields' shape is omitted, since object properties can't represent them.
      def apply_nested_subfields!(prop, config, nested_subfields)
        return if nested_subfields.blank?
        return unless object_shaped?(config)

        prop[:type] = "object"
        prop.delete(:format)
        prop[:properties] ||= {}
        prop[:required] ||= []

        nested_subfields.each do |subconfig|
          if subconfig.validations[:model]
            id_field, subprop = model_id_property(subconfig)
            # A user may declare an explicit nested `<field>_id` subfield before the `model:` subfield;
            # don't clobber it with the generic model-generated one.
            prop[:properties][id_field] ||= subprop
            prop[:required] << id_field.to_s unless optional_for_schema?(subconfig, subfield: true)
          else
            prop[:properties][subconfig.field] = build_property(subconfig, subfield: true)
            prop[:required] << subconfig.field.to_s unless optional_for_schema?(subconfig, subfield: true)
          end
        end

        prop[:required] = prop[:required].uniq
        prop[:required] = nil if prop[:required].empty?
      end

      # Every exposed field is always present in the serialized output: Values.serialize_exposed iterates
      # every outbound config and emits its key (value nil when unset). JSON Schema `required` means
      # property PRESENCE, not non-nullness, so every exposed field is `required`; nullability is carried
      # by the property `type` ("null").
      def build_output(field_configs)
        properties = {}
        required = []

        field_configs.each do |config|
          properties[config.field] = build_property(config, for_output: true).compact
          required << config.field.to_s
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Deep-copy a reflected literal (a `default:` value or an inclusion enum member) and normalize any
      # leaf whose JSON wire form differs from its Ruby form — Time/DateTime/Date → iso8601 String,
      # Symbol → String, non-Integer/Float Numeric (BigDecimal/Rational) → Float — so the emitted
      # `default`/`enum` matches the property's advertised type. Scalar wire coercion is delegated to
      # Values.serialize_value (the single source of truth for it), so the two never drift. Mutable
      # String leaves are duped so a consumer mutating the returned schema can't reach the stored
      # contract; an unrecognized object is left as-is (schema literals are already simple values,
      # so this deliberately does NOT follow Values.serialize_value's as_json/to_h coercion).
      def normalize_schema_literal(value)
        # Only EXACT built-in containers are traversed/duped (instance_of?, not is_a?): an Array/Hash/
        # String SUBCLASS could override map/each_with_object/dup with user code, and reflection must stay
        # side-effect-free — so a subclass (like any other unrecognized object) is left opaque.
        if value.instance_of?(Hash)
          # Dup mutable String keys too (leaving them shared would let a consumer mutating a returned key
          # in place corrupt FieldConfig#default).
          value.each_with_object({}) { |(k, v), h| h[k.instance_of?(String) ? k.dup : k] = normalize_schema_literal(v) }
        elsif value.instance_of?(Array)
          value.map { |v| normalize_schema_literal(v) }
        elsif value.instance_of?(String)
          value.dup
        elsif value.is_a?(Symbol) || value.is_a?(Time) || value.is_a?(Date) || value.is_a?(Numeric)
          Values.serialize_value(value)
        else
          value
        end
      end

      # The `enum:` member list for an inclusion set. `nullable` (nil_allowed?) is the runtime truth: when
      # false, a literal `nil` member is dropped (an explicit nil is rejected there); when true, `nil` is
      # added if not already present.
      def enum_for_inclusion(enum_values, nullable:)
        members = normalize_schema_literal(enum_values)
        return members.compact unless nullable

        # Identity check, not include?/==: an enum member with a custom `==` must not run during reflection.
        members.any? { |m| m.equal?(nil) } ? members : members + [nil]
      end

      def build_property(config, for_output: false, subfield: false)
        prop = {}
        prop[:description] = config.description if config.description

        type_info = json_type_for(config.validations, for_output:)
        nullable = nil_allowed?(config)
        if type_info[:anyOf]
          members = type_info[:anyOf]
          members = drop_uuid_format(members) if type_allows_blank?(config)
          prop[:anyOf] = nullable ? members + [{ type: "null" }] : members
        elsif type_info[:type]
          prop[:type] = nullable ? [type_info[:type], "null"] : type_info[:type]
          # A `type: :uuid, allow_blank: true` field accepts "" at runtime (TypeValidator treats a blank
          # uuid as valid under allow_blank), but a strict `format: "uuid"` validator would reject "".
          # Drop the uuid format there so the schema doesn't reject a value the contract accepts.
          prop[:format] = type_info[:format] if type_info[:format] && !(type_info[:format] == "uuid" && type_allows_blank?(config))
        end

        if config.respond_to?(:default) && !config.default.nil? && !config.default.is_a?(Proc)
          # Only a truthy subfield default is applied at runtime, so a falsey `default: false` subfield
          # must not advertise a default the runtime never applies. Top-level defaults apply by key-presence.
          emit_default = subfield ? !!config.default : true
          prop[:default] = normalize_schema_literal(config.default) if emit_default
        end

        if (inclusion = config.validations[:inclusion])
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          # Exact Array only: an Array subclass could override the traversal used to build the enum, and
          # reflection must not run user code. A subclass set simply reflects no enum.
          prop[:enum] = enum_for_inclusion(enum_values, nullable:) if enum_values.instance_of?(Array)
        end

        apply_structured_schema!(prop, config, for_output:)

        prop
      end

      # Combine of: (bare element baseline) and shape: (typed member contracts) into items:/properties:.
      # Precedence: shape: enriches/overrides of: baseline.
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
          # Hash / class field — shape: members are the object's own properties. A shaped object field IS
          # an object, even when the field's declared type: (e.g. a Data.define subclass) isn't in TYPE_MAP.
          #
          # On OUTPUT this holds only when the value serializes to a member-keyed object (its type defines
          # `to_h`). A reader-only object with no `to_h` serializes to a String (to_s) — so leave that
          # output field untyped rather than promise an `object` serialize_exposed won't produce. Input is
          # unaffected: the shape describes the JSON object a client is expected to send.
          return if for_output && !shape_serializes_to_object?(config)

          prop[:type] = nil_allowed?(config) ? %w[object null] : "object"
          prop.delete(:format)
          member_props, required = member_properties(shape[:members], for_output:)
          type_klass = config.validations.dig(:type, :klass)
          base_props = type_klass.is_a?(Class) && type_klass < Data ? type_klass.members.to_h { |m| [m, {}] } : {}
          prop[:properties] = base_props.merge(member_props)
          prop[:required] = required unless required.empty?
        end
      end

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
          { type: "object", properties: klass.members.to_h { |m| [m, {}] } }
        else
          json_type_for({ type: klass }, for_output:)
        end
      end

      def member_properties(members, for_output:)
        props = {}
        required = []
        members.each do |m|
          props[m.field] = build_property(m, for_output:).compact
          required << m.field.to_s unless optional_for_schema?(m)
        end
        [props, required]
      end

      # Returns [id_field_symbol, prop_hash] for a model: config. No type constraint: `find`/custom
      # finders accept any nonblank PK token, and inferring the real PK type would require a DB load.
      def model_id_property(config)
        model_opts = config.validations[:model]
        klass = model_opts[:klass]
        klass_name = klass.is_a?(Class) ? klass.name : klass.to_s
        id_field = :"#{config.field}_id"
        prop = { description: config.description || "ID of the #{klass_name} record" }
        [id_field, prop.compact]
      end

      def build_model_property(config, properties, required, field_configs)
        id_field, prop = model_id_property(config)
        # A user may declare an explicit `<field>_id` field before the `model:` field; don't clobber it
        # or double-add to `required`.
        properties[id_field] ||= prop
        return if required.include?(id_field.to_s)

        # The generated id is omittable when the model field itself is, OR when an explicitly-declared
        # `<field>_id` field is optional (e.g. carries a default) — inbound defaults run before the model
        # lookup, so that default supplies the id and the omitted call succeeds.
        explicit_id = field_configs.find { |c| c.field == id_field }
        return if optional_for_schema?(config) || (explicit_id && field_optional?(explicit_id, []))

        required << id_field.to_s
      end

      def single_type_for(klass, for_output:)
        return { type: "boolean" } if klass == :boolean
        return { type: "string", format: "uuid" } if klass == :uuid
        return { type: "object" } if klass == :params

        # A declared type that ADMITS a Complex value (`type: Numeric` or `type: Complex`, i.e. Complex is
        # the class or one of its ancestors) can serialize to a JSON number (real Numerics) OR a String
        # (Complex — Float() rejects it, so Values.serialize_value falls back to to_s). Its output wire
        # form isn't knowable from the declaration, so leave it UNTYPED on output rather than assert
        # "number" the serialized value could contradict. Input still resolves below: `Numeric` maps to
        # "number" (a JSON number is a real Numeric and validates), `Complex` to the permissive "string".
        return {} if for_output && klass.is_a?(Class) && klass >= Complex

        if TYPE_MAP.key?(klass)
          result = { type: TYPE_MAP[klass] }
          result[:format] = FORMAT_MAP[klass] if FORMAT_MAP.key?(klass)
          return result
        end

        # A Numeric subclass not in TYPE_MAP (BigDecimal, Rational, …) serializes to a JSON number
        # (Values.serialize_value coerces it via Float()), so reflect it as "number" rather than the
        # object/string fallback. Complex is the exception: Float() rejects it, so on input it drops to
        # the permissive "string" below (a JSON client can't send a Complex anyway; output is handled
        # above).
        return { type: "number" } if klass.is_a?(Class) && klass < Numeric && !(klass <= Complex)

        # Unknown class: the serialized shape is only knowable at runtime (Values.serialize_value emits
        # an object for an as_json/to_h value but a string for a to_s-only one), so on output leave it
        # UNTYPED rather than assert `object` the serialized value might contradict. On input, keep a
        # permissive `string` hint (a JSON client can't send a Ruby object anyway — see the reflection
        # docs on coercing Ruby-object input types).
        return {} if for_output

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
          # Exact Array only (see build_property): don't traverse an Array subclass to infer the type.
          if enum_values.instance_of?(Array) && enum_values.any?
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

      # Whether the field's validators, taken together, permit a nil/omitted value. Drives both
      # input optionality and nullability (adding "null" to the emitted type). A lone validator's
      # allow_nil: doesn't count if another (presence, type, …) still rejects nil.
      #
      # An entry is nil-tolerant if it's a disabled validator (`opt == false`), `absence` (nil is always
      # "absent"), `acceptance` unless explicitly `allow_nil: false` (ActiveModel's acceptance is allow_nil
      # by default), a Hash allowing nil/blank, an `exclusion` set not containing nil, or an `inclusion`
      # set that explicitly contains nil. Any other active validator — including a bare `true` (e.g.
      # `numericality: true`) — rejects nil.
      def nil_accepted?(config)
        v = config.validations
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end

      def nil_tolerant_validation?(key, opt)
        return true if opt == false
        return true if opt.is_a?(Hash) && (opt[:allow_nil] || opt[:allow_blank])
        return true if key == :absence
        return true if key == :acceptance && !(opt.is_a?(Hash) && opt[:allow_nil] == false)
        return true if key == :exclusion && set_includes_nil?(opt) == false
        return true if key == :inclusion && set_includes_nil?(opt) == true

        false
      end

      # Tri-state: nil = can't tell; true/false = nil's membership in the set. Only inspected for in-memory
      # literal collections: reflection must stay side-effect-free, so a dynamic collection (e.g. an
      # ActiveRecord::Relation, whose `include?` would query the database) is treated as unknown (nil).
      # Detection is identity-based (`equal?(nil)`), never `include?`/`==`: an element with a custom `==`
      # could itself run user code. A Range's bounds are Comparable, so nil is never a member.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      def set_includes_nil?(opt)
        return nil unless opt.is_a?(Hash)

        collection = opt[:in] || opt[:within]
        return false if collection.is_a?(Range)
        return nil unless collection.instance_of?(Array) || (defined?(Set) && collection.instance_of?(Set))

        collection.any? { |element| element.equal?(nil) }
      rescue StandardError
        nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

      def nil_allowed?(config)
        nil_accepted?(config)
      end

      # Whether the TYPE validator itself tolerates a blank value (`type: :uuid, allow_blank: true`
      # folds `allow_blank` into the type validator's options). Only the type validator's own option
      # matters for dropping `format: "uuid"` — a blank-tolerant `length:`/other validator doesn't make
      # `TypeValidator` accept `""`, so the format must stay.
      def type_allows_blank?(config)
        type = config.validations[:type]
        type.is_a?(Hash) && type[:allow_blank] == true
      end

      # Strip `format: "uuid"` from anyOf members: a blank-tolerant uuid accepts "" at runtime, which a
      # strict `format: uuid` validator would reject (mirrors the scalar-type relaxation above).
      def drop_uuid_format(members)
        members.map { |m| m[:format] == "uuid" ? m.except(:format) : m }
      end
    end
  end
end
