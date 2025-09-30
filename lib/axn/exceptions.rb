# frozen_string_literal: true

module Axn
  module Internal
    # Internal only -- rescued before Axn::Result is returned
    class EarlyCompletion < StandardError; end
  end

  # Raised when fail! is called
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    attr_reader :source

    def initialize(message = nil, source: nil)
      @source = source
      @message = message
      super(message)
    end

    def message
      @message.presence || DEFAULT_MESSAGE
    end

    def default_message? = message == DEFAULT_MESSAGE

    def inspect = "#<#{self.class.name} '#{message}'>"
  end

  module Attachable
    class AttachmentError < ArgumentError; end
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
    class DefaultAssignmentError < ContractViolation; end

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

  class UnsupportedArgument < ArgumentError
    def initialize(feature)
      @feature = feature
      super()
    end

    def message
      "#{@feature} is not currently supported.\n\n" \
        "Implementation is technically possible but very complex. " \
        "Please submit a Github Issue if you have a real-world need for this functionality."
    end
  end
end
