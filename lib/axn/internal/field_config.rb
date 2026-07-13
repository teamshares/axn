# frozen_string_literal: true

module Axn
  module Internal
    # Naming conventions derived from a field's name, plus the duck-typed optionality predicate
    # (other config-object predicates live on Axn::Core::Contract::FieldConfig itself).
    module FieldConfig
      module_function

      # A field is optional when it carries no `presence: true` validation, or any validator
      # tolerates blank. Duck-typed on `#validations` — axn-mcp calls this with FieldConfig AND
      # ShapeConfig objects (nested shape members), so it must stay a module function here (see
      # spec/downstream_contracts/axn_mcp_interface_spec.rb); FieldConfig#optional? delegates in.
      def optional?(config)
        validations = config.validations
        return true unless validations.key?(:presence) && validations[:presence] == true

        validations.values.any? { |v| v.is_a?(Hash) && v[:allow_blank] == true }
      end

      # The generated `<field>_id` key for a `model:` field — the lookup-token reader Axn derives from
      # the model field's name. Single source of the `_id` suffix convention (the model resolver, the
      # `<field>_id` reader, sensitive-key/ambient filtering, and schema reflection all key off it).
      #
      # @param field [Symbol, String] the model field's name (or its `as:` reader)
      # @return [Symbol] the `<field>_id` key
      def model_id_key(field)
        :"#{field}_id"
      end
    end
  end
end
