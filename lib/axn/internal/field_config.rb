# frozen_string_literal: true

# Resolving a default or a preprocessor raises through the shared contract-error wrapper, which raises axn's
# own exception classes — both runtime references, so a process that loaded this file alone (reflection loads
# it for the `model:` id convention) would NameError on the first failing default rather than at require time.
require "axn/exceptions"
require "axn/internal/contract_error_handling"

module Axn
  module Internal
    # Naming conventions derived from a field's name (config-object predicates live on the config
    # types themselves — see Axn::Core::Contract::FieldConfig / ShapeConfig).
    module FieldConfig
      module_function

      # The ActiveModel shared-option keys that conditionally gate a declaration's validators
      # (`expects :x, ..., if:`/`unless:`). They ride the validations hash as sibling keys but are
      # not validators themselves: the tolerance push-down skips them, reflection treats them as
      # neutral, and the contradiction detectors treat a gated declaration as relaxable.
      CONDITIONAL_GATE_KEYS = %i[if unless].freeze

      # The validator key `allow_empty: false` installs its own check under (ActiveModel resolves it to
      # NonEmptinessValidator). Framework-installed only — absent from KNOWN_VALIDATION_KEYS, so a declaration
      # cannot spell it. THE single name for it, shared by the declaration that installs it (contract.rb
      # `_reconcile_emptiness_axis!`) and by schema reflection's `minItems`/`minProperties`/`minLength`
      # emission, so what the runtime rejects and what the schema advertises cannot drift. It lives here, with
      # the gate keys, because both are declaration keys the reflection layer reads: that keeps the builder's
      # load graph free of the validator kernel, which is not loadable on its own.
      NON_EMPTINESS_KEY = :non_emptiness

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
      # DefaultAssignmentError. Single source for the outbound-defaults write pass (Executor
      # #apply_defaults!, which fills exposed_data) AND the value-level read-path fallback
      # (PRO-2889), so the two can't drift on Proc/error semantics.
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

      # Run a config's preprocess proc against an action instance, wrapping failures as
      # PreprocessingError. Used by the read-path resolution (ContractForSubfields.resolve_value) for
      # both top-level and subfield preprocess — mirrors resolve_default's error-wrapping shape.
      def resolve_preprocess(action, config, value)
        descriptor = config.subfield? ? "subfield '#{config.field}' on '#{config.on}'" : "field '#{config.field}'"
        identifier = config.subfield? ? "#{config.field} on #{config.on}" : config.field
        Axn::Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: Axn::ContractViolation::PreprocessingError,
          message: ->(_field, error) { "Error preprocessing #{descriptor}: #{error.message}" },
          field_identifier: identifier,
        ) do
          action.instance_exec(value, &config.preprocess)
        end
      end
    end
  end
end
