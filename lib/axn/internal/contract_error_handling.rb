# frozen_string_literal: true

module Axn
  module Internal
    module ContractErrorHandling
      module_function

      # Executes a block, allowing fail! and done! to propagate normally,
      # but wrapping other StandardErrors in the specified exception class.
      #
      # @param exception_class [Class] The exception class to wrap errors in
      # @param message [String, Proc] Error message or proc that takes (field_identifier, error)
      # @param field_identifier [String] Identifier for the field (for error messages)
      # @yield The block to execute
      # @raise [Axn::Failure] Re-raised if raised in block
      # @raise [Axn::Internal::EarlyCompletion] Re-raised if raised in block
      # @raise [exception_class] Wrapped exception for other StandardErrors
      def with_contract_error_handling(exception_class:, message:, field_identifier:)
        yield
      rescue Axn::Failure, Axn::Internal::EarlyCompletion => e
        raise e # Re-raise control flow exceptions without wrapping
      rescue StandardError => e
        error_message = if message.is_a?(Proc)
                          message.call(field_identifier, e)
                        else
                          format(message, field_identifier, e.message)
                        end
        raise exception_class, error_message, cause: e
      end
    end
  end
end
