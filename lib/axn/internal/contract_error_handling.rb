# frozen_string_literal: true

# The two flow-control exceptions this re-raises are rescued by class, so the class has to exist by the time a
# wrapped block raises anything.
require "axn/exceptions"
require "axn/internal/rendering"

module Axn
  module Internal
    module ContractErrorHandling
      module_function

      # Executes a block, allowing fail! to propagate normally, refusing done!, and wrapping other
      # StandardErrors in the specified exception class.
      #
      # A `done!` here is refused rather than propagated: a default:/preprocess: produces a value, and a
      # successful early exit from inside one would leave its field unresolved while claiming success,
      # skipping the validation that guarantees the result's shape. `fail!` stays legal — a failure
      # promises no exposures, so ending the call with one cannot break that guarantee.
      #
      # @param exception_class [Class] The exception class to wrap errors in
      # @param message [String, Proc] Error message or proc that takes (field_identifier, error)
      # @param field_identifier [String] Identifier for the field (for error messages)
      # @param operation [String] What the block is doing, for the refused-done! message
      # @yield The block to execute
      # @raise [Axn::Failure] Re-raised if raised in block
      # @raise [Axn::MisplacedFlowControl] In place of a done! raised in block
      # @raise [exception_class] Wrapped exception for other StandardErrors
      def with_contract_error_handling(exception_class:, message:, field_identifier:, operation:)
        yield
      rescue Axn::Internal::EarlyCompletion
        raise Axn::MisplacedFlowControl.new(signal: "done!", operation:)
      rescue Axn::Failure => e
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
