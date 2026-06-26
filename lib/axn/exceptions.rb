# frozen_string_literal: true

module Axn
  module Internal
    # Internal only -- rescued before Axn::Result is returned
    class EarlyCompletion < StandardError
      attr_reader :prefixed

      def initialize(message = nil, prefixed: true)
        @prefixed = prefixed
        super(message)
      end
    end
  end

  # Raised when fail! is called
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    # The action whose `fail!` raised this. We hold the action OBJECT (compared by identity in
    # Result#_fail_prefixed?), not its object_id — consistent with ExceptionClassification's
    # identity keying, which deliberately avoids the freed-then-reused-object_id collision hazard.
    # `prefixed:` is scoped to that action: an ancestor that catches a bubbled child Failure still
    # applies its OWN base prefix (the child's opt-out is local).
    # NOTE: this pins the action (and its context/inputs) for the Failure's lifetime — only relevant
    # if a bare `result.exception` is retained beyond its result; results are normally short-lived.
    attr_reader :__originating_action, :raw_reason

    def initialize(message = nil, prefixed: true, action: nil)
      @raw_reason = message
      @presentation = nil
      @prefixed = prefixed
      @__originating_action = action
      super(message)
    end

    # Set the resolved, presentation-layer string shown by #message. Leaves raw_reason untouched so
    # the framework can keep re-resolving from the raw reason without double-prefixing.
    def __present_as(string) = @presentation = string.presence

    def prefixed? = @prefixed
    def message = @presentation.presence || @raw_reason.presence || DEFAULT_MESSAGE
    # Must be read before any presentation is stamped (i.e. at the originating level); once
    # __present_as is called, #message returns the stamped presentation — not the raw default.
    def default_message? = message == DEFAULT_MESSAGE
    def inspect = "#<#{self.class.name} '#{message}'>"
  end

  module Mountable
    class MountingError < ArgumentError; end
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

    # Like other ContractViolations raised inside `call`, propagates from `call!` but surfaces as `result.exception` under `.call`.
    class NoMatchingExposures < ContractViolation
      def initialize(declared:, exposed:)
        @declared = declared
        @exposed = exposed
        super()
      end

      def message
        "expose(result): the result exposes #{@exposed.inspect} but this action declares " \
          "#{@declared.inspect} — no fields in common to forward"
      end
    end
  end

  class DuplicateFieldError < ContractViolation; end

  class ValidationError < ContractViolation
    attr_reader :errors, :user_facing_message

    # `user_facing:` marks an inbound validation failure that the Executor has reclassified into the
    # failure bucket (see `expects ..., user_facing:`). The structured `errors` are preserved on the
    # exception either way; `user_facing_message` carries the (possibly overridden) message that
    # surfaces on `result.error` as a prefixable reason — headlined by a declared base `error` just
    # like a `fail!` reason — leaving the dev-facing `#message` (full validation errors) intact.
    def initialize(errors, user_facing: false, user_facing_message: nil)
      @errors = errors
      @user_facing = user_facing
      @user_facing_message = user_facing_message
      super(errors)
    end

    # Single source of truth for "did this (arbitrary) exception settle into the user-facing failure
    # bucket?" — folds in the `is_a?` guard so the Executor (classification) and Result (outcome +
    # surfaced reason) ask the question one way and can't drift apart.
    def self.user_facing?(exception) = exception.is_a?(self) && exception.user_facing?

    def user_facing? = @user_facing
    def __present_as(string) = @presentation = string.presence
    def message = @presentation.presence || errors.full_messages.to_sentence
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

  module Async
    # Raised at enqueue when an async argument cannot be serialized for background execution.
    # Field-aware: names the offending field, its class, and how to fix it. The fix hint is
    # delegated to the serialization layer (Axn::Internal::AsyncSerialization), resolved at
    # message time so this stays a pure exception definition.
    class UnserializableArgument < ArgumentError
      def initialize(field:, value:)
        @field = field
        @value = value
        super()
      end

      def message
        "Cannot serialize argument `#{@field}` (#{@value.class}) for async execution. " \
          "#{Axn::Internal::AsyncSerialization._unserializable_hint(@value)}"
      end
    end
  end
end
