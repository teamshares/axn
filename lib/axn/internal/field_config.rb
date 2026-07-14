# frozen_string_literal: true

module Axn
  module Internal
    # Naming conventions derived from a field's name (config-object predicates live on the config
    # types themselves — see Axn::Core::Contract::FieldConfig / ShapeConfig).
    module FieldConfig
      module_function

      # The generated `<field>_id` key for a `model:` field — the lookup-token reader Axn derives from
      # the model field's name. Single source of the `_id` suffix convention (the model resolver, the
      # `<field>_id` reader, sensitive-key/ambient filtering, and schema reflection all key off it).
      #
      # @param field [Symbol, String] the model field's name (or its `as:` reader)
      # @return [Symbol] the `<field>_id` key
      def model_id_key(field)
        :"#{field}_id"
      end

      # Resolve a config's declared default against an action instance: a Proc is instance_exec'd (so
      # it sees readers/context), anything else returned as-is, with failures wrapped as
      # DefaultAssignmentError. Single source for the executor's write-back pass AND the value-level
      # read fallback (PRO-2889), so the two can't drift on Proc/error semantics.
      def resolve_default(action, config)
        descriptor = config.subfield? ? "subfield '#{config.field}' on '#{config.on}'" : "field '#{config.field}'"
        identifier = config.subfield? ? "#{config.field} on #{config.on}" : config.field
        Axn::Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: Axn::ContractViolation::DefaultAssignmentError,
          message: ->(_field, error) { "Error applying default for #{descriptor}: #{error.message}" },
          field_identifier: identifier,
        ) do
          config.default.respond_to?(:call) ? action.instance_exec(&config.default) : config.default
        end
      end
    end
  end
end
