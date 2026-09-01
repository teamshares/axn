# frozen_string_literal: true

module Axn
  module Internal
    # Per-(exception, action, entry) cache of a `fails_on` entry's `if:`/`unless:` condition
    # verdict. `_fails_on?` computes it once, at classification time; that entry's own wired
    # message gate then reuses the SAME verdict instead of re-invoking the condition — so a
    # condition runs at most once per exception PER SETTLING ACTION INSTANCE, and classification
    # and the message it gates can never disagree even if the condition is stateful (a counter, a
    # clock, anything not perfectly pure). Without this, a condition returning a different answer
    # on its second call would classify one way and present the other: reclassified as a failure
    # with the wrong (base/generic) message, or left an exception while still surfacing the
    # failure-only message.
    #
    # `action` is part of the key, not just `exception`/`entry`, because a `fails_on` entry is
    # INHERITED (`_fails_on_entries` is a `class_attribute`) — the same `Entry` object can be
    # consulted for the SAME exception at more than one settlement level when a subclass shares its
    # base's declaration (an inner action's own settlement, then an outer one it bubbles into via
    # `call!`). The condition is documented and evaluated as ACTION-scoped (`self` inside it is the
    # settling action), so the inner and outer instances asking about the very same exception must
    # get INDEPENDENT verdicts, each evaluated against its own `self` -- collapsing them onto one
    # cache slot would make the outer action's classification silently depend on the inner action's
    # (a DIFFERENT object, answering a DIFFERENT `self`) instead of asking its own condition at all.
    #
    # Mirrors ExceptionClassification/CarriedPresentation: scoped via IsolatedExecutionState,
    # identity-keyed at every level (compare_by_identity) so neither the exception, the action, nor
    # a `fails_on` `Entry`'s own `==`/`hash` (a `Data.define`, structurally compared by default) can
    # make two distinct things collide, and cleared when the nesting stack empties (see
    # NestingTracking) so a later independent run starts fresh.
    module FailsOnVerdicts
      class << self
        def fetch(exception, action, entry) = _entries_for(exception, action)[entry]
        def record!(exception, action, entry, verdict) = (_entries_for(exception, action)[entry] = verdict)

        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_fails_on_verdicts] = nil
        end

        private

        def _entries_for(exception, action)
          by_exception = (ActiveSupport::IsolatedExecutionState[:_axn_fails_on_verdicts] ||= {}.compare_by_identity)
          by_action = (by_exception[exception] ||= {}.compare_by_identity)
          by_action[action] ||= {}.compare_by_identity
        end
      end
    end
  end
end
