# frozen_string_literal: true

# Resolving a default or a preprocessor raises through the shared contract-error wrapper, which raises axn's
# own exception classes — both runtime references, so a process that loaded this file alone (reflection loads
# it for the `model:` id convention) would NameError on the first failing default rather than at require time.
require "axn/exceptions"
require "axn/internal/contract_error_handling"
require "axn/internal/rendering"

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
        descriptor = describe_field(config)
        identifier = identify_field(config)
        Axn::Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: Axn::ContractViolation::DefaultAssignmentError,
          message: ->(_field, error) { "Error applying default for #{rendered(descriptor)}: #{rendered_exception_message(error)}" },
          field_identifier: identifier,
        ) do
          config.default.respond_to?(:call) ? action.instance_exec(&config.default) : config.default
        end
      end

      # Run a config's preprocess proc against an action instance, wrapping failures as
      # PreprocessingError. Used by the read-path resolution (ContractForSubfields.resolve_value) for
      # both top-level and subfield preprocess — mirrors resolve_default's error-wrapping shape.
      def resolve_preprocess(action, config, value)
        descriptor = describe_field(config)
        identifier = identify_field(config)
        Axn::Internal::ContractErrorHandling.with_contract_error_handling(
          exception_class: Axn::ContractViolation::PreprocessingError,
          message: ->(_field, error) { "Error preprocessing #{rendered(descriptor)}: #{rendered_exception_message(error)}" },
          field_identifier: identifier,
        ) do
          action.instance_exec(value, &config.preprocess)
        end
      end

      # How a field is named in these wrappers' messages, and the identifier they carry alongside. Each is a
      # composition of its own — `describe_field` joins two declared names in its subfield branch,
      # `identify_field` likewise — so each normalizes its OWN operands at its own join, exactly as the message
      # lambdas above normalize theirs. Two Latin-1 names join as they stand; a UTF-8 one beside a Latin-1 one
      # raises, so a nested join owes the same discipline as an outer one.
      #
      # What those lambdas deliberately do NOT do is trust these return values: `describe_field` picks one of
      # two shapes, so the outer join renders whatever it chose rather than depending on both branches having
      # rendered everything they interpolate. A third branch added later is then already covered.
      #
      # `Reflection::PropertyNames.renderable_label` is the same rendering one layer up, and deliberately not
      # reached from here: that file requires THIS one, so a reference back would be a require cycle. `rendered`
      # is what this layer can honestly get — `value_rendering` renders a String from its bytes with nothing
      # dispatched, and a Symbol through its own `to_s` (which a Symbol cannot override), while a name that is
      # neither is named by its CLASS, the fallback every composed message here takes.
      def describe_field(config)
        return "field '#{rendered(config.field)}'" unless config.subfield?

        "subfield '#{rendered(config.field)}' on '#{rendered(config.on)}'"
      end

      # The `field_identifier` the wrapper carries. A top-level field is passed as the NAME itself rather
      # than as text — nothing joins it here, and the wrapper's own message path renders it where it does.
      def identify_field(config)
        return config.field unless config.subfield?

        "#{rendered(config.field)} on #{rendered(config.on)}"
      end

      # THE normalization point for every join in this module.
      def rendered(value)
        Axn::Internal::Rendering.value_rendering(value) || Axn::Internal::Rendering.class_name(value)
      end

      # An exception's message is read through the one guarded reader; naming it here keeps both lambdas short
      # enough to read as compositions.
      def rendered_exception_message(error) = Axn::Internal::Rendering.exception_message(error)

      private_class_method :describe_field, :identify_field, :rendered, :rendered_exception_message
    end
  end
end
