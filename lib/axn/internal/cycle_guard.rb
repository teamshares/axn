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
      # Placeholders matching Ruby's inspect output for a recursive container. Walkers that build
      # strings can emit these directly; walkers that build data structures substitute their own
      # (e.g. a redaction mask) so they never hand a placeholder string back as real data.
      HASH_PLACEHOLDER = "{...}"
      ARRAY_PLACEHOLDER = "[...]"

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
