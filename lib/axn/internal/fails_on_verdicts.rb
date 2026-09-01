# frozen_string_literal: true

module Axn
  module Internal
    # Per-exception-object cache of each `fails_on` entry's `if:`/`unless:` condition verdict.
    # `_fails_on?` computes it once, at classification time; that entry's own wired message gate
    # then reuses the SAME verdict instead of re-invoking the condition — so a condition runs at
    # most once per exception, and classification and the message it gates can never disagree even
    # if the condition is stateful (a counter, a clock, anything not perfectly pure). Without this,
    # a condition returning a different answer on its second call would classify one way and
    # present the other: reclassified as a failure with the wrong (base/generic) message, or left an
    # exception while still surfacing the failure-only message.
    #
    # Mirrors ExceptionClassification/CarriedPresentation: scoped via IsolatedExecutionState,
    # identity-keyed at both levels (compare_by_identity) so neither the exception nor a `fails_on`
    # `Entry`'s own `==`/`hash` (a `Data.define`, structurally compared by default) can make two
    # distinct things collide, and cleared when the nesting stack empties (see NestingTracking) so
    # a later independent run starts fresh.
    module FailsOnVerdicts
      class << self
        def fetch(exception, entry) = _entries_for(exception)[entry]
        def record!(exception, entry, verdict) = (_entries_for(exception)[entry] = verdict)

        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_fails_on_verdicts] = nil
        end

        private

        def _entries_for(exception)
          store = (ActiveSupport::IsolatedExecutionState[:_axn_fails_on_verdicts] ||= {}.compare_by_identity)
          store[exception] ||= {}.compare_by_identity
        end
      end
    end
  end
end
