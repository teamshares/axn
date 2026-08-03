# frozen_string_literal: true

require "axn/internal/text"

module Axn
  module Internal
    # The name of a value's class, derived WITHOUT dispatching anything the value can override.
    # An error message that names the offending value's class by calling `value.class` (or `inspect`)
    # runs the value's own code at the moment the error is being built, so the value can replace the
    # failure being reported with an exception of its own — and one outside StandardError then escapes
    # the `rescue StandardError` callers map these failures with, which is the escape naming the class
    # is meant to describe. A bound base implementation cannot be intercepted.
    #
    # Not dispatching is ALL this promises. What it returns is the constant path's own bytes, and a constant
    # may hold non-UTF-8 ones (`Object.const_set(:"Caf\xE9", Class.new)` is accepted, and `Module#to_s` hands
    # those bytes back), so interpolating the result into a UTF-8 message can still raise
    # Encoding::CompatibilityError from the reporting itself. A layer writing a class name into prose therefore
    # renders it — `Internal::Rendering.class_name`/`module_name` compose both halves for every caller above
    # this file, and the two message paths built ON this file (`UnserializableValue#message` below,
    # `Reflection::Values.describe_key_classes`) compose them by hand for the same reason `Rendering` itself
    # cannot: reaching up from here into the reflection layer, which requires THIS file, would leave a message
    # path NameError-ing under the standalone loads `spec/axn/standalone_require_spec.rb` pins. The byte half
    # both compose through, `Internal::Text`, has no requires of its own and sits below all three.
    module ClassName
      OBJECT_CLASS = ::Object.instance_method(:class)
      MODULE_TO_S = ::Module.instance_method(:to_s)
      private_constant :OBJECT_CLASS, :MODULE_TO_S

      # `Module#to_s` rather than `#name`, which is nil for an anonymous class; to_s always returns a
      # String ("#<Class:0x…>" there).
      def self.of(value) = MODULE_TO_S.bind_call(OBJECT_CLASS.bind_call(value))

      # The name of a class or module ITSELF, rather than of a value's class — for a message that names a
      # declared type. Same reasoning: a class can define its own `to_s`, and one that raises would replace
      # the failure being reported.
      def self.of_module(mod) = MODULE_TO_S.bind_call(mod)
    end

    # Internal only -- rescued before Axn::Result is returned
    class EarlyCompletion < StandardError
      attr_reader :standalone

      def initialize(message = nil, standalone: false)
        @standalone = standalone
        super(message)
      end
    end
  end

  # Raised when fail! is called
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    # The action whose `fail!` raised this. We hold the action OBJECT (compared by identity in
    # Result#_fail_standalone?), not its object_id — consistent with ExceptionClassification's
    # identity keying, which deliberately avoids the freed-then-reused-object_id collision hazard.
    # `standalone:` is scoped to that action: an ancestor that catches a bubbled child Failure still
    # applies its OWN base (the child's opt-out is local).
    # NOTE: this pins the action (and its context/inputs) for the Failure's lifetime — only relevant
    # if a bare `result.exception` is retained beyond its result; results are normally short-lived.
    attr_reader :__originating_action, :raw_reason

    def initialize(message = nil, standalone: false, action: nil)
      @raw_reason = message
      @presentation = nil
      @standalone = standalone
      @__originating_action = action
      super(message)
    end

    # Set the resolved, presentation-layer string shown by #message. Leaves raw_reason untouched so
    # the framework can keep re-resolving from the raw reason without double-prefixing.
    def __present_as(string) = @presentation = string.presence

    def standalone? = @standalone
    def message = @presentation.presence || @raw_reason.presence || DEFAULT_MESSAGE
    # Keyed off the RAW reason, not #message: once __present_as stamps the resolved presentation,
    # #message no longer reflects whether the caller supplied a reason. Post-run consumers read this
    # on a finalized, stamped result (e.g. ContextFacadeInspector#status → "[failed]" vs "[failed with…]").
    def default_message? = (@raw_reason.presence || DEFAULT_MESSAGE) == DEFAULT_MESSAGE
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

    # Raised by FieldResolvers::Extract when a source can hold neither the named key nor answer it
    # as a method. Inside the subfield contract machinery this is rescued and treated as "value
    # absent" (PRO-2857), so the malformed value's own validation classifies it; it surfaces
    # publicly only when a reader meets malformed data outside validation (e.g. an untyped parent
    # read in the action body).
    class UnextractableError < ContractViolation; end

    # Raised by FieldResolvers::Extract when a segment can only be resolved by INVOKING it as a
    # method (an Array method, a PORO reader, a Data behavioral method) but the declaration did not
    # opt into method dispatch with `method_call: true`. Kept DISTINCT from UnextractableError so
    # `extract_or_nil` does NOT swallow it to "absent" — a forgotten `method_call:` must surface
    # loudly rather than silently validate the field against nil. As a plain ContractViolation (not
    # a ValidationError, not user_facing:) it settles as a bug: the executor fires the global
    # on_exception and result.error shows the generic headline, while the actionable fix rides on
    # this exception's own #message (see the design at PRO-2898).
    class MethodCallNotPermittedError < ContractViolation; end

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

  # Raised by `Axn.validate_tool_contracts!` for a tool whose contract failure cannot be reported AS ITSELF.
  # Reporting it as itself means renaming it to say which tool it came from, and renaming an exception runs the
  # exception's own code — `#exception`, which `raise` dispatches on whatever object it is handed, and the
  # duplication hooks `Exception#exception(message)` reaches. axn will not run that code while reporting the
  # failure it caused (an override that raises replaces the failure, and one outside StandardError escapes the
  # boot rescue entirely), so when the class owns any of it, axn reports its own error instead.
  #
  # Nothing is lost but the class: the original is this error's `cause`, and its message is repeated here.
  # Deliberately the only exception in this file that builds its text in `initialize` rather than in `#message`.
  # Everything it needs is already a plain String by the time it is constructed, so there is nothing to defer —
  # and this exception exists precisely because reporting must not depend on an exception's own methods, so it
  # renders identically through `#message`, through a bound `Exception#to_s`, and to anything that reads the
  # stored message directly.
  #
  # Every value it interpolates came from somewhere else's object — the tool's constant path, the original's
  # message, the original's class name — so each is RENDERED into this message rather than joined to it. Bytes
  # with no UTF-8 rendering (or in another encoding entirely) would otherwise raise
  # Encoding::CompatibilityError from `super` itself, replacing the tool-contract failure with an encoding
  # failure at boot, which is the outcome this error exists to prevent one indirection over. Rendering is
  # idempotent, so the caller having already rendered them (as `Axn.validate_tool_contracts!` does, needing the
  # same text for its other branch) costs an allocation and changes nothing: the guarantee holds for any caller
  # rather than resting on that one's diligence.
  #
  # This file cannot REQUIRE the renderer (the reflection layer requires this file), so the reference resolves at
  # call time — sound here and not for `Internal::ClassName` above, because the only code that can construct this
  # error is `Axn.validate_tool_contracts!`, which lives in the fully-loaded gem, while a class name is written
  # into prose by files an adapter loads standalone.
  class InvalidToolContract < ContractViolation
    def initialize(tool:, reason:, original_class:)
      tool, reason, original_class = [tool, reason, original_class].map { |text| Axn::Reflection::PropertyNames.renderable_label(text) }

      super("#{tool} has an invalid tool contract — #{reason} (raised as #{self.class}, and not as the original " \
            "#{original_class}, because that class supplies its own `#exception` or duplication hook, or the " \
            "object is frozen: axn does not run an exception's own code while reporting the failure it caused. " \
            "The original is this error's `cause`.)")
    end
  end

  class ValidationError < ContractViolation
    attr_reader :errors, :user_facing_message

    # `user_facing:` marks an inbound validation failure that the Executor has reclassified into the
    # failure bucket (see `expects ..., user_facing:`). The structured `errors` are preserved on the
    # exception either way; `user_facing_message` carries the (possibly overridden) message that
    # surfaces on `result.error` as an attachable reason — headlined by a declared base `error` just
    # like a `fail!` reason — leaving the dev-facing `#message` (full validation errors) intact.
    def initialize(errors, user_facing: false, user_facing_message: nil)
      @errors = errors
      @user_facing = user_facing
      @user_facing_message = user_facing_message
      @presentation = nil # set by __present_as when an owned, user-facing failure is stamped (see Axn::Failure)
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

    # Structured per-field view of the validation errors, for callers that want to format each
    # failure individually (e.g. a tool adapter handing per-argument reasons back to a model).
    # `full_message` so each entry reads standalone; base-level errors surface with field == :base.
    def field_errors = errors.map { |error| { field: error.attribute, message: error.full_message } }
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

  module Reflection
    # Raised when an exposed value has no honest JSON representation, so a serializing adapter
    # (axn-openapi, axn-mcp, axn-ruby_llm) fails the call rather than emitting garbage or a placeholder
    # where data belongs. Six shapes, in two categories. The rendering would be WRONG, or not JSON at
    # all: a self-referential container (no JSON representation at all), two Hash keys that stringify
    # to one JSON property (a value silently dropped), a non-finite Float (no JSON literal exists), or
    # a String whose bytes have no UTF-8 rendering (JSON is a UTF-8 format). The rendering would be
    # UGLY, rejected only under `serialize_value(reject_opaque: true)`: a value or a Hash key whose
    # only `to_s` is the inherited Object#to_s, which renders an object address into a response body.
    #
    # An ArgumentError so an adapter's existing `rescue StandardError` maps it to an error response
    # with no adapter-side change; a SystemStackError, being outside StandardError, would escape the
    # adapter entirely. Names the path to the offending value.
    class UnserializableValue < ArgumentError
      # `reason:` names the specific defect, punctuation included. It defaults to the cycle case —
      # both the original meaning of this error and the only one an external caller is likely to
      # construct — so `new(path:, value:)` remains a complete call.
      def initialize(path:, value:, reason: nil)
        @path = path
        @value = value
        @reason = reason
        super()
      end

      # The offending value's class is named via Axn::Internal::ClassName, not `@value.class`: the value
      # is caller-supplied and may override `class`, and running that override here would replace this
      # failure with the value's own exception. Its bytes are foreign too — a constant may hold non-UTF-8
      # ones, and `Module#to_s` hands those back — so the name is RENDERED before it joins this message.
      # This composes `Internal::Rendering.class_name` by hand (`Text.renderable(ClassName.of(...))`)
      # rather than calling it: `rendering.rb` requires this file, so calling back into it here would be a
      # require cycle. Do not "tidy" this into a delegation.
      def message
        "Cannot serialize exposed value at `#{@path}` (#{value_class_name}): #{@reason || cycle_reason}"
      end

      private

      def value_class_name = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of(@value))

      def cycle_reason
        klass = value_class_name
        article = klass.match?(/\A[aeiou]/i) ? "an" : "a"

        "it is self-referential (#{article} #{klass} cycle), which has no JSON representation. " \
          "Expose a finite projection of it instead (e.g. ids rather than the objects that point back)."
      end
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
