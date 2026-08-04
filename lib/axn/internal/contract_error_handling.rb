# frozen_string_literal: true

# The two flow-control exceptions this re-raises are rescued by class, so the class has to exist by the time a
# wrapped block raises anything.
require "axn/exceptions"
require "axn/internal/rendering"

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
                          # Both operands of the format go through the renderer, not just the exception's
                          # message: the identifier is a declared NAME, so a UTF-8 message beside a Latin-1
                          # name raises `Encoding::CompatibilityError` out of `format` itself — the wrapper
                          # reporting an encoding failure in place of the contract failure it exists to name.
                          # Two raw operands in the same encoding joined fine, so rendering only one is
                          # strictly worse than rendering neither.
                          format(message, _rendered_identifier(field_identifier),
                                 Axn::Internal::Rendering.exception_message(e))
                        end
        raise exception_class, error_message, cause: e
      end

      # A declared name (or the text a caller composed from some) as a UTF-8 String this layer owns. Only the
      # `format` branch above needs it — a Proc `message:` receives the identifier as it came, and renders it
      # itself where it writes it into prose (see `Internal::FieldConfig`).
      def _rendered_identifier(identifier)
        Axn::Internal::Rendering.value_rendering(identifier) || Axn::Internal::Rendering.class_name(identifier)
      end
    end
  end
end
