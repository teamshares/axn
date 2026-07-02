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
            nested_subfields = subfields_by_parent[config.reader_as]
            if nested_subfields&.any? && prop[:type] == "object"
              prop[:properties] ||= {}
              prop[:required] ||= []
              nested_subfields.each do |subconfig|
                if subconfig.validations[:model]
                  id_field, subprop = model_id_property(subconfig)
                  prop[:properties][id_field] = subprop
                  prop[:required] << id_field.to_s unless optional_for_schema?(subconfig)
                else
                  subprop = build_property(subconfig)
                  prop[:properties][subconfig.field] = subprop
                  prop[:required] << subconfig.field.to_s unless optional_for_schema?(subconfig)
                end
              end
              prop[:required] = nil if prop[:required].empty?
            end

            properties[config.field] = prop.compact
            required << config.field.to_s unless optional_for_schema?(config)
          end
        end

        schema = { type: "object", properties: }
        schema[:required] = required unless required.empty?
        schema
      end

      def build_output(field_configs)
        properties = {}
        required = []

        field_configs.each do |config|
          prop = build_property(config, for_output: true)
          properties[config.field] = prop.compact
          required << config.field.to_s unless optional_for_schema?(config)
        end

        schema = { type: "object", properties: }
        schema[:required] = required unless required.empty?
        schema
      end

      def build_property(config, for_output: false)
        prop = {}
        prop[:description] = config.description if config.description

        type_info = json_type_for(config.validations, for_output:)
        if type_info[:anyOf]
          prop[:anyOf] = type_info[:anyOf]
        else
          prop[:type] = type_info[:type] if type_info[:type]
          prop[:format] = type_info[:format] if type_info[:format]
        end

        prop[:default] = config.default if config.respond_to?(:default) && !config.default.nil? && !config.default.is_a?(Proc)

        if (inclusion = config.validations[:inclusion])
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          prop[:enum] = enum_values if enum_values.is_a?(Array)
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

        if prop[:type] == "array"
          items = of ? items_schema_for(of, for_output:) : {}
          if shape
            member_props, required = member_properties(shape[:members], for_output:)
            base_props = items[:properties] || {}
            items = items.merge(type: "object", properties: base_props.merge(member_props))
            items[:required] = required unless required.empty?
          end
          prop[:items] = items unless items.empty?
        elsif shape
          # Hash / class field — shape: members are the object's own properties.
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
          required << m.field.to_s unless optional?(m)
        end
        [props, required]
      end

      # Returns [id_field_symbol, prop_hash] for a model: config. Integer only for the default :find
      # finder (id-based PK); a custom finder's token type is unknown, so leave it unconstrained.
      def model_id_property(config)
        model_opts = config.validations[:model]
        klass = model_opts[:klass]
        klass_name = klass.is_a?(Class) ? klass.name : klass.to_s
        id_field = :"#{config.field}_id"
        prop = { description: config.description || "ID of the #{klass_name} record" }
        prop[:type] = "integer" if model_opts[:finder] == :find
        [id_field, prop.compact]
      end

      def build_model_property(config, properties, required)
        id_field, prop = model_id_property(config)
        properties[id_field] = prop
        required << id_field.to_s unless optional_for_schema?(config)
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
            sample = enum_values.first
            return { type: "string" } if sample.is_a?(String)
            return { type: "integer" } if sample.is_a?(Integer)
            return { type: "number" } if sample.is_a?(Float)
          end
        end

        if validations[:numericality]
          numericality = validations[:numericality]
          return { type: "integer" } if numericality.is_a?(Hash) && numericality[:only_integer]

          return { type: "number" }
        end

        return { type: "string" } if validations[:presence] || validations[:length]

        {}
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

      # A field is optional in the schema (client may omit it) iff it has a default, or a validation
      # explicitly allows nil/blank. A typed field with neither (e.g. type: :boolean) is required —
      # TypeValidator rejects nil. (This subsumes the earlier default?-based check.)
      def optional_for_schema?(config)
        return true if default?(config)

        config.validations.values.any? { |opt| opt.is_a?(Hash) && (opt[:allow_nil] || opt[:allow_blank]) }
      end
    end
  end
end
