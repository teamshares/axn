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
