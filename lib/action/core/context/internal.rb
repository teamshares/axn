# frozen_string_literal: true

require "action/core/context/facade"

module Action
  # Inbound / Internal ContextFacade
  class InternalContext < ContextFacade
    # So can be referenced from within e.g. error_from callables
    def default_error
      [@context.error_prefix, determine_error_message(only_default: true)].compact.join(" ").squeeze(" ")
    end

    private

    def context_data_source = @context.provided_data

    def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
      if @context.__combined_data.key?(method_name.to_sym)
        msg = <<~MSG
          Method ##{method_name} is not available on Action::InternalContext!

          #{action_name} may be missing a line like:
            expects :#{method_name}
        MSG

        raise Action::ContractViolation::MethodNotAllowed, msg
      end

      super
    end
  end
end
