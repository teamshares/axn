# frozen_string_literal: true

module Axn
  module Validation
    # Shared kernel for the one-off ActiveModel validator classes Fields and Subfields build: the
    # custom validator constants and symbol-argument delegation to the action. Subclasses supply the
    # value source (`read_attribute_for_validation`) and how to reach the action
    # (`_action_for_validation`).
    class Base
      include ActiveModel::Validations

      # NOTE: exposing the validators as constants here (rather than registering them globally)
      # scopes them to axn's own one-off validator classes, so they can't affect the consuming
      # apps' validators.
      ModelValidator = Validators::ModelValidator
      TypeValidator = Validators::TypeValidator
      ValidateValidator = Validators::ValidateValidator
      OfValidator = Validators::OfValidator
      ShapeValidator = Validators::ShapeValidator

      # Normalize a scalar validator value the way ActiveModel's own `validates` does, so the tolerance
      # push-down (contract.rb `_parse_field_validations`) can layer allow_blank:/allow_nil: onto the
      # SAME options hash `validates` would build — the terse spelling (`numericality: true`,
      # `inclusion: [..]`/`1..5`, `format: /re/`) then combines transparently with a tolerance flag,
      # matching how it behaves WITHOUT one (PRO-2915). Reuses AM's private `_parse_validates_options`
      # rather than copying its case statement, so the mapping cannot drift (activemodel 7.2.2.2:
      # TrueClass→{}, Hash→itself, Range/Array→{in:}, else→{with:}).
      def self.normalize_validator_options(value) = _parse_validates_options(value)

      # ActiveModel's shared "default" validator options — keys that ride alongside validator entries
      # in a `validates` call but are NOT validators themselves (if:/unless:/on:/strict:/allow_blank:/
      # allow_nil:). Exposed so the tolerance push-down (contract.rb) can hold them OUT of the
      # per-validator scalar normalization — merging tolerance into `strict: true`, say, would rewrite
      # it to a Hash and break strict raising. Reuses AM's own canonical list so the set can't drift.
      def self.shared_validation_option_keys = _validates_default_keys

      # The real VALIDATOR entries in a validations hash — everything that is NOT an ActiveModel shared
      # option (if:/unless:/on:/strict:/allow_blank:/allow_nil:). THE single definition of "is this a
      # validator", shared by the validator-class builder, the gate sweeps, and schema reflection, so
      # "does this field have any validators / do its validators accept nil" is decided one way
      # everywhere. Without it, a shared-only hash like `{ strict: true }` reads as a validator: the
      # builder calls `validates` and ActiveModel raises "You need to supply at least one validation",
      # and reflection marks the (omittable) field required.
      def self.validator_entries(validations) = validations.except(*shared_validation_option_keys)

      # Delegate unknown methods to the action instance so symbol-referenced validation arguments
      # (e.g. `inclusion: { in: :valid_channels_for_number }`) resolve against the action — for
      # top-level fields and subfields alike.
      def method_missing(method_name, ...)
        action = _action_for_validation
        return super unless action && action.respond_to?(method_name, true) # rubocop:disable Style/SafeNavigation

        action.send(method_name, ...)
      end

      def respond_to_missing?(method_name, include_private = false)
        action = _action_for_validation
        return super unless action

        action.respond_to?(method_name, include_private) || super
      end

      private

      def _action_for_validation = nil
    end

    # Carrier object for errors aggregated ACROSS validator instances (top-level + subfield + model
    # consistency in one settled exception). ActiveModel::Errors renders full messages through its
    # base's class (human_attribute_name), so the base must be an ActiveModel::Validations-bearing
    # object — an action instance isn't one.
    class Aggregate
      include ActiveModel::Validations

      def self.name = "Axn::Validation::Aggregate"
    end
  end
end
