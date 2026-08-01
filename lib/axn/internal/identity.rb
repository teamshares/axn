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

      # True when `one` and `other` are the same object.
      def self.same?(one, other) = EQUAL.bind_call(one, other)

      # True when `value` IS nil — the undispatched form of `value.nil?`.
      def self.nil_value?(value) = EQUAL.bind_call(value, nil)
    end
  end
end
