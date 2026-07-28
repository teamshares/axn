# frozen_string_literal: true

module Axn
  module Internal
    # Guards a recursive walk over caller-supplied containers against self-referential (cyclic)
    # structures. Every walker that descends into arbitrary Hash/Array values for observability —
    # log formatting, exception-report formatting, facet coercion, sensitive masking — would
    # otherwise recurse to SystemStackError on `a = [1]; a << a`, taking down the call from a side
    # channel (SystemStackError is not a StandardError, so it escapes the normal result path).
    #
    # Mirrors what Ruby's own #inspect does for recursive structures: emit a placeholder for the
    # container already open on the current path. Identity-keyed (`compare_by_identity`), never
    # `==`/`hash`: a cycle is about the same OBJECT reappearing, and a large or custom-`==`
    # container must not be compared by value here.
    module CycleGuard
      # Renders as Ruby's inspect output for a recursive container, WITHOUT the surrounding quotes a
      # plain String would gain when a formatter inspects it — so a decycled copy reads the same as a
      # guarded walk (`[...]`, not `"\"[...]\""`). Still a String subclass, so ParameterFilter, JSON
      # serializers, and an error tracker's own formatting all treat it as the ordinary string it is.
      class Placeholder < String
        def inspect = self
      end

      HASH_PLACEHOLDER = Placeholder.new("{...}").freeze
      ARRAY_PLACEHOLDER = Placeholder.new("[...]").freeze

      # A structurally-equal copy of `value` with every self-referential container replaced by its
      # placeholder, so the result can be handed to code that has no cycle guard of its own — namely
      # ActiveSupport::ParameterFilter, which axn cannot fix in place. For that fallback only: a walker
      # axn owns should guard its own recursion with .guard instead, which needs no copy.
      def self.decycle(value, seen = nil)
        case value
        when Hash
          guard(value, seen, on_cycle: HASH_PLACEHOLDER) { |nested| value.transform_values { |element| decycle(element, nested) } }
        when Array
          guard(value, seen, on_cycle: ARRAY_PLACEHOLDER) { |nested| value.map { |element| decycle(element, nested) } }
        else
          value
        end
      end

      # Yields the visited-set to use for the next level down, having marked `container` as open.
      # Returns `on_cycle` instead — without yielding — when `container` is already open on the
      # current path.
      #
      # `seen` is nil at the top of a walk and allocated on first descent, so an acyclic scalar
      # costs nothing. Membership is popped on the way out (ensure), so a container repeated among
      # SIBLINGS still renders in full — again matching Ruby, where `x = [1]; [x, x].inspect` is
      # `"[[1], [1]]"`, not `"[[1], [...]]"`. Only genuine ancestry is a cycle.
      def self.guard(container, seen, on_cycle:)
        seen ||= {}.compare_by_identity
        return on_cycle if seen.key?(container)

        seen[container] = true
        begin
          yield seen
        ensure
          seen.delete(container)
        end
      end
    end
  end
end
