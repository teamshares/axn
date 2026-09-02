# frozen_string_literal: true

require "axn/internal/current_entry_point"
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

      def with(value, &)
        Axn::Internal::CurrentEntryPoint.with(value, &)
      end
    end
  end
end
