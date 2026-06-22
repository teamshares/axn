# frozen_string_literal: true

module Axn
  module Internal
    # A `fails_on`-matched exception is classified as a *failure* (an expected outcome, not a bug) by
    # the action that declared `fails_on`. That classification has to travel with the **specific
    # exception object** as it propagates through nested `call!`s, so ancestor executors treat it as
    # a failure too — fire `on_failure`, skip the global report — exactly like `Axn::Failure` (which
    # is sticky via its class).
    #
    # Keyed on the object, never the class: an unrelated instance of the same class raised elsewhere
    # is untagged and remains a reportable exception.
    module ExceptionClassification
      IVAR = :@__axn_classified_failure

      def self.failure?(exception) = !exception.nil? && exception.instance_variable_defined?(IVAR)

      def self.mark_failure!(exception)
        exception.instance_variable_set(IVAR, true)
      rescue StandardError
        # Frozen/odd exceptions can't carry the flag; worst case the classification isn't sticky for
        # that object — never a crash.
        nil
      end
    end
  end
end
