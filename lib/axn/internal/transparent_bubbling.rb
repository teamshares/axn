# frozen_string_literal: true

module Axn
  module Internal
    # The tail shared by `call!` and `forward!`, the two entry points that bubble a completed
    # result's outcome transparently: an ok result is returned untouched, and any other outcome
    # re-raises that result's own exception object, so the caller settles on the original error
    # rather than on a synthesized one. Re-raising the same object is what preserves the exception's
    # identity — a `fails_on`-classified error still matches the caller's own `error ..., if:
    # SomeError` — and what lets the identity-keyed carry below reach the caller.
    module TransparentBubbling
      class << self
        def bubble!(result)
          return result if result.ok?

          # Carry this result's presentation for an ancestor to prefix onto (header aggregation).
          # Scoped to the transparent-bubbling entry points on purpose: a child run via plain `.call`
          # must NOT leave a carried presentation, or an explicit `.call` + re-raise (e.g. `step`'s
          # bug path) would leak it into the parent. Two gates: (1) only when an Axn ancestor is
          # still on the stack to consume it -- at the OUTERMOST `call!`, `call` above has already
          # unwound NestingTracking (and run its reset), so a write here would have no consumer and
          # no later reset (a thread-local leak that also pins the Failure's
          # __originating_action/context); `forward!` always has its own action on the stack, so its
          # write always has one. (2) Only when a base/reason was actually declared, so a baseless
          # fallback contributes nothing.
          if Axn::Core::NestingTracking._current_axn_stack.any? && result.send(:_error_from_declared_source?)
            CarriedPresentation.set(result.exception, result.error)
          end

          raise result.exception
        end
      end
    end
  end
end
