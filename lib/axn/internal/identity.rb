# frozen_string_literal: true

module Axn
  module Internal
    # Identity comparisons that cannot be intercepted by the objects being compared.
    #
    # Axn accepts caller-supplied collaborators whose contract is one named method and nothing else — a
    # `tracer` promises `#in_span`. Asking such an object whether it is `nil`, or whether it is the same
    # object as another, by dispatching `nil?`/`equal?` to it means a proxy that overrides or forwards
    # those can change or break an answer axn relies on. The binding comes from BasicObject rather than
    # Object so it holds for a BasicObject-based proxy too, which is the shape most likely to forward
    # everything through method_missing.
    module Identity
      EQUAL = BasicObject.instance_method(:equal?)
      private_constant :EQUAL

      # Module#===, which resolves an object's type without consulting any `is_a?`/`kind_of?` the
      # object itself defines. Held as an UnboundMethod and called rather than written as the `===`
      # operator, so the intent is legible at each call site and the type test stays in one place.
      KIND = Module.instance_method(:===)
      private_constant :KIND

      CLASS_OF = Object.instance_method(:class)
      MODULE_NAME = Module.instance_method(:to_s)
      private_constant :CLASS_OF, :MODULE_NAME

      STRIP = String.instance_method(:strip)
      EMPTY = String.instance_method(:empty?)
      private_constant :STRIP, :EMPTY

      ENCODE = String.instance_method(:encode)
      DUP = String.instance_method(:dup)
      FORCE_ENCODING = String.instance_method(:force_encoding)
      SCRUB = String.instance_method(:scrub)
      VALID_ENCODING = String.instance_method(:valid_encoding?)
      private_constant :ENCODE, :DUP, :FORCE_ENCODING, :SCRUB, :VALID_ENCODING

      # True when `one` and `other` are the same object.
      def self.same?(one, other) = EQUAL.bind_call(one, other)

      # True when `value` IS nil — the undispatched form of `value.nil?`.
      def self.nil_value?(value) = EQUAL.bind_call(value, nil)

      # True when `value` is an instance of `klass` — the undispatched form of `value.is_a?(klass)`,
      # for a `value` whose own answer axn has no reason to trust.
      def self.kind?(value, klass) = KIND.bind_call(klass, value)

      # `value`'s class, read through Object's own `#class`. A config object can declare a setting named
      # `class`, whose generated reader shadows it — so dispatching would hand back the setting's value
      # where a Class was expected.
      def self.class_of(value) = CLASS_OF.bind_call(value)

      # A caller-supplied value rendered for an error message, which must not be able to replace that
      # error. `inspect` IS dispatched, deliberately: the object's own is what makes a message useful
      # (`"foo"` rather than `#<String:0x…>`), and rendering everything through Object#inspect would
      # degrade every well-behaved value to defend against broken ones. So the call is made and its
      # failure absorbed instead.
      #
      # Absorbs every class, including those axn never swallows. An `inspect` that raises is an ordinary
      # bug — an uninitialized ivar, a broken association — and on an error path the exception being
      # reported has to win over anything raised while describing it. A non-String `inspect` is treated
      # as a failure too, since interpolating it would dispatch again.
      def self.describe(value)
        rendered = value.inspect
        kind?(rendered, String) ? utf8_string(rendered) : undescribable(value)
      rescue Exception # rubocop:disable Lint/RescueException
        undescribable(value)
      end

      # Names the value's CLASS without asking the value anything. Nested rescue because `class_of`
      # binds an Object method, which a BasicObject-based proxy cannot receive at all.
      def self.undescribable(value)
        "#<#{MODULE_NAME.bind_call(class_of(value))} (inspect unavailable)>"
      rescue Exception # rubocop:disable Lint/RescueException
        "#<unrenderable value>"
      end

      # A caller-supplied String rendered so it can be interpolated into a UTF-8 message. Transcoding
      # is attempted first, since that preserves the text a UTF-16 reason actually says; a String whose
      # bytes cannot be transcoded falls back to being reinterpreted as UTF-8 and scrubbed, which is
      # lossy but always succeeds. Without this, joining the reason to axn's own message raises
      # `Encoding::CompatibilityError` — reporting a validation failure would REPLACE it with an
      # encoding error, which is the one thing an error path may not do.
      #
      # Undispatched throughout: the String came from a caller's `validate:` lambda and may be a
      # subclass overriding any of these.
      # ALWAYS returns valid UTF-8, which is the contract callers depend on: transcoding a String
      # already TAGGED UTF-8 succeeds without validating it, so the encode alone can hand back invalid
      # bytes that raise later — `strip` on them raises Encoding::CompatibilityError, which is exactly
      # the failure this method exists to prevent.
      def self.utf8_string(value)
        encoded = ENCODE.bind_call(value, Encoding::UTF_8)
        VALID_ENCODING.bind_call(encoded) ? encoded : SCRUB.bind_call(encoded)
      rescue StandardError
        SCRUB.bind_call(FORCE_ENCODING.bind_call(DUP.bind_call(value), Encoding::UTF_8))
      end

      # True when a String is empty or only whitespace, read through String's OWN implementations. A
      # subclass may override `strip`/`empty?`, and this runs while an error is already being raised —
      # dispatching there lets the caller's method replace that error with anything it likes, including
      # a class the surrounding rescue was never meant to catch. Caller must have checked `kind?` first.
      def self.blank_string?(value) = EMPTY.bind_call(STRIP.bind_call(value))
    end
  end
end
