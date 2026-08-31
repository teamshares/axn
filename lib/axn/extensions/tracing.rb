# frozen_string_literal: true

# Declared rather than inherited from the top-level `axn` entrypoint's require order, for the reason
# axn/internal/reflection/values.rb gives about its own: both calls below are runtime references, so a
# standalone load of this file would NameError on the first call rather than at require time.
require "axn/internal/tracing"
require "axn/extensions"

# `current_span` reaches Core::NestingTracking, which needs ActiveSupport — required here (this facade,
# not `axn/internal/tracing.rb`) so that file's own pre-existing standalone-loadability stays untouched
# by a method it never calls (see that file's comment). A real Bundler-managed consumer already has
# ActiveSupport reachable as one of axn's own gemspec dependencies; this only makes the require explicit
# rather than relying on load-order luck.
require "axn/core/nesting_tracking"

module Axn
  module Extensions
    # The `axn.call` span, published for a downstream gem that must write vendor-namespaced attributes
    # it cannot know at declaration time (`gen_ai.*`, `db.*`, ...) — an app annotating its OWN domain
    # data belongs to the `tag`/`dimension` DSL instead (declared once, cardinality-aware, resolved into
    # every sink: span, notification payload, logs, `emit_metrics`, exception report, Sidekiq tags).
    #
    # Named for the OTel concept it stands in for at the call site (`Axn::Extensions::Tracing`, not a
    # bare `Extensions.current_span` — see `lib/axn/extensions.rb`'s own scope for why this earns its
    # own module rather than joining the grab-bag), and reads naturally alongside `Internal::Tracing`,
    # which owns the mechanism this is a facade over.
    module Tracing
      module_function

      # The span axn's tracer yielded for the innermost currently-executing action, or nil. See
      # `Internal::Tracing.current_span` for every case this answers nil in — no tracer, an untraced
      # fallback run, no ancestor fallback, the known fiber-isolation-mismatch guard — and PRO-3278 for
      # why this exists instead of `OpenTelemetry::Trace.current_span`.
      #
      # Valid only for the duration of the action's own body: a reference held past the call has
      # already ended (do not call `finish` on it, do not cache it for later).
      def current_span = Axn::Internal::Tracing.current_span

      # Sets each attribute on `current_span`, or does nothing (no raise) when there is none. The
      # documented default over the raw accessor: it absorbs the nil-span check, the `best_effort`
      # guard, skipping a nil value (not a valid OTel attribute — the SDK would log-and-drop it anyway),
      # and Symbol->String key coercion (OTel attribute keys are Strings) — the four things the one real
      # consumer we had (`axn-ruby_llm`'s `record_otel_attributes!`) got wrong by hand, silently dropping
      # every attribute against the ambient lookup this seam replaces.
      def annotate_span(**attrs)
        span = current_span
        return unless span

        Axn::Extensions.best_effort("annotating the axn.call span") do
          attrs.each do |key, value|
            next if value.nil?

            span.set_attribute(key.to_s, value)
          end
        end
      end
    end
  end
end
