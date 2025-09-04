# frozen_string_literal: true

require "axn/core/context/facade"

module Axn
  # Inbound / Internal ContextFacade
  class InternalContext < ContextFacade
    def default_error = _msg_resolver(:error, exception: Axn::Failure.new).resolve_default_message
    def default_success = _msg_resolver(:success, exception: nil).resolve_default_message

    private

    def _context_data_source = @context.provided_data

    def method_missing(method_name, ...) # rubocop:disable Style/MissingRespondToMissing (because we're not actually responding to anything additional)
      if @context.__combined_data.key?(method_name.to_sym)
        msg = <<~MSG
          Method ##{method_name} is not available on Axn::InternalContext!

          #{action_name} may be missing a line like:
            expects :#{method_name}
        MSG

        raise Axn::ContractViolation::MethodNotAllowed, msg
      end

      super
    end
  end
end
