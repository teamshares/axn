# frozen_string_literal: true

require "action/core/context/facade"

module Action
  # Inbound / Internal ContextFacade
  class InternalContext < ContextFacade
    # Available for use from within message callables
    def default_error
      # Look for the first user-defined error message without conditions
      _find_first_static_message(:error) || "Something went wrong"
    end

    def default_success
      # Look for the first user-defined success message without conditions
      _find_first_static_message(:success) || "Action completed successfully"
    end

    private

    def context_data_source = @context.provided_data

    def _find_first_static_message(event_type)
      # The registry stores handlers in "last-defined-first" order, so we need to reverse
      # to get the order they were defined (first-defined-first)
      handlers = action.class._messages_registry.for(event_type).reverse

      handlers.each do |handler|
        # A handler is static if it has no matcher (no conditions)
        if handler.respond_to?(:static?) && handler.static?
          msg = handler.apply(action:, exception: @context.exception || Action::Failure.new)
          return msg if msg.present?
        end
      end
      nil
    end

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
