# frozen_string_literal: true

require "axn/internal/current_entry_point"
require "axn/core/tagging"
require "axn/extensions"

module Axn
  module Extensions
    # Declares WHY a call tree is running, for a gem that dispatches axns on behalf of an external
    # trigger (an inbound webhook, a scheduled shift, a queue consumer) but is not itself a tool
    # adapter. Axn::Tools::Invoker calls this same API internally for every registered tool adapter, so
    # there is exactly one mechanism behind both: a tool adapter gets it automatically via the Invoker;
    # everything else opts in with one call at its own dispatch choke point.
    #
    # The value becomes the `invoked_via` dimension (Internal::CurrentEntryPoint::DIMENSION_NAME) on
    # every axn in the wrapped call tree, including nested sub-axns and any Sidekiq job enqueued from
    # inside it (an enqueue-time job tag only — the PERFORMED job runs in a different process, where
    # this is unset). No action may declare `dimension :invoked_via` / `tag :invoked_via` itself
    # (Core::Tagging rejects it at declaration) — this is the only way to set it.
    #
    # Nests safely (each `with` restores the previous value on the way out), but nesting isn't the
    # intended shape: call it once, at the outermost point your gem controls, around the whole dispatch.
    #
    #   Axn::Extensions::InvokedVia.with(:webhooks) { handler_class.call!(**args) }
    module InvokedVia
      module_function

      # Coerced and duped through Core::Tagging's own helpers — the same treatment a declared facet's
      # resolved value gets — ONCE here, rather than by each Executor that later reads it. That is load
      # bearing, not just tidy: every axn in the wrapped tree is meant to report the identical value
      # (subtree semantics), and a caller is free to keep mutating whatever mutable object they passed
      # in after this call returns — reusing a buffer between two `.call`s inside the same block needs
      # no access to axn internals at all. Detaching from the caller's object HERE, before it is ever
      # stored, means every executor in the tree — however many calls happen inside the block, however
      # the caller's own object changes afterward — reads the exact same already-safe value rather than
      # re-deriving its own copy from a reference that may have moved on by the time it looks.
      #
      # Wrapped in best_effort for the same reason `Core::Tagging.resolve` guards each facet's own
      # resolver: an object whose #to_s raises must not turn a side channel into `.call` raising
      # directly (it runs in Executor#initialize, before `run` ever reaches the exception boundary) —
      # `nil` (best_effort's failure return) leaves the tree unstamped rather than broken.
      #
      # `nil` is preserved rather than run through `coerce` — `Tagging.coerce(nil)` falls to its
      # `else value.to_s` branch and returns `""`, which is a value, not an absence: every sink would
      # stamp an empty `invoked_via` (including a real Sidekiq job tag) for what both
      # `Invoker.new(adapter: nil)` and a declared facet returning nil treat as "no stamp at all."
      # `false` is unaffected — it matches `coerce`'s own `String, true, false` branch and passes
      # through as a legal, present value, same as it always has.
      def with(value, &)
        safe_value = _safe_value(value)
        Axn::Internal::CurrentEntryPoint.with(safe_value, &)
      end

      def _safe_value(value)
        return nil if value.nil?

        Axn::Extensions.best_effort("coercing the invoked_via stamp") do
          Core::Tagging.dup_value(Core::Tagging.coerce(value))
        end
      end
      private_class_method :_safe_value
    end
  end
end
