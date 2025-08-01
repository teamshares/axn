# frozen_string_literal: true

module Action
  # Raised internally when fail! is called
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    def initialize(message = nil, **)
      @message = message
      super(**)
    end

    def message
      @message.presence || DEFAULT_MESSAGE
    end

    def inspect = "#<#{self.class.name} '#{message}'>"
  end

  class ContractViolation < StandardError
    class ReservedAttributeError < ContractViolation
      def initialize(name)
        @name = name
        super()
      end

      def message = "Cannot call expects or exposes with reserved field name: #{@name}"
    end

    class MethodNotAllowed < ContractViolation; end
    class PreprocessingError < ContractViolation; end

    class UnknownExposure < ContractViolation
      def initialize(key)
        @key = key
        super()
      end

      def message = "Attempted to expose unknown key '#{@key}': be sure to declare it with `exposes :#{@key}`"
    end
  end

  class DuplicateFieldError < ContractViolation; end

  class ValidationError < ContractViolation
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super
    end

    def message = errors.full_messages.to_sentence
    def to_s = message
  end

  class InboundValidationError < ValidationError; end
  class OutboundValidationError < ValidationError; end
end
