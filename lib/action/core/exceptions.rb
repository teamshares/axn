# frozen_string_literal: true

module Action
  # Raised internally when fail! is called -- triggers failure + rollback handling
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

  class StepsRequiredForInheritanceSupportError < StandardError
    def message
      <<~MSG
        ** Inheritance support requires the following steps: **

        Add this to your Gemfile:
          gem "interactor", github: "kaspermeyer/interactor", branch: "fix-hook-inheritance"

        Explanation:
          Unfortunately the upstream interactor gem does not support inheritance of hooks, which is required for this feature.
          This branch is a temporary fork that adds support for inheritance of hooks, but published gems cannot specify a branch dependency.
          In the future we may inline the upstream Interactor gem entirely and remove this necessity, but while we're in alpha we're continuing
          to use the upstream gem for stability (and there has been recent activity on the project, so they *may* be adding additional functionality
          soon).
      MSG
    end
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
