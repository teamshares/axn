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

      STRIP = String.instance_method(:strip)
      EMPTY = String.instance_method(:empty?)
      private_constant :STRIP, :EMPTY

      # True when `one` and `other` are the same object.
      def self.same?(one, other) = EQUAL.bind_call(one, other)

      # True when `value` IS nil — the undispatched form of `value.nil?`.
      def self.nil_value?(value) = EQUAL.bind_call(value, nil)

      # True when `value` is an instance of `klass` — the undispatched form of `value.is_a?(klass)`,
      # for a `value` whose own answer axn has no reason to trust.
      def self.kind?(value, klass) = KIND.bind_call(klass, value)

      # True when a String is empty or only whitespace, read through String's OWN implementations. A
      # subclass may override `strip`/`empty?`, and this runs while an error is already being raised —
      # dispatching there lets the caller's method replace that error with anything it likes, including
      # a class the surrounding rescue was never meant to catch. Caller must have checked `kind?` first.
      def self.blank_string?(value) = EMPTY.bind_call(STRIP.bind_call(value))
    end
  end
end
