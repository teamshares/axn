# frozen_string_literal: true

# Declared rather than inherited from the top-level `axn` entrypoint's require order: the guard is
# needed at RUNTIME (not load time), so relying on that order means a NameError on first use for
# any load path that does not go through it.
require "axn/internal/cycle_guard"
require "axn/internal/identity"
require "axn/internal/reflection/property_names"
require "axn/internal/rendering"
require "axn/internal/text"
require "axn/extensions"
require "axn/core/logging"
require "axn/core/tagging"

module Axn
  module Internal
    # Logs action execution - handles building and emitting structured log
    # messages for action calls with context formatting and truncation.
    module CallLogger
      extend self

      MAX_CONTEXT_LENGTH = 150
      TRUNCATION_SUFFIX = "…<truncated>…"

      # `would_log?`'s predicate for each of `Core::Logging::LEVELS`, precomputed so the common case
      # never builds `:"#{level}?"` — a fresh String allocation (PRO-3335: `would_log?` is now called
      # from both the Executor's before/after hooks and from inside `log_at_level` itself, so a naive
      # per-call interpolation would cost 2 allocations per emitted line, a net regression on the
      # benchmark this ticket is trying to improve, whose configured logger's level is always on).
      LEVEL_PREDICATES = Core::Logging::LEVELS.to_h { |level| [level, :"#{level}?"] }.freeze

      # Logs a message at the specified level with error handling
      # @param action_class [Class] The action class to log from
      # @param level [Symbol] The log level (e.g., :info, :warn)
      # @param message_parts [Array<String>] Parts of the message to join
      # @param error_context [String] Context for error reporting if logging fails
      # @param join_string [String] String to join message parts with
      # @param before [String, nil] Text to prepend to the message
      # @param after [String, nil] Text to append to the message
      # @param prefix [String, nil] Override the default log prefix (useful for class-level logging)
      # @param context_direction [Symbol, nil] Direction for context logging (:inbound or :outbound)
      # @param context_instance [Object, nil] Action instance for instance-level context_for_logging
      # @param context_data [Hash, nil] Raw data for class-level context_for_logging
      # @param facets [Hash, nil] Resolved observability facets ({ tags:, dimensions: }) to annotate the line with
      def log_at_level( # rubocop:disable Metrics/ParameterLists
        action_class,
        level:,
        message_parts:,
        error_context:,
        join_string: " ",
        before: nil,
        after: nil,
        prefix: nil,
        context_direction: nil,
        context_instance: nil,
        context_data: nil,
        facets: nil
      )
        return unless level

        Axn::Extensions.best_effort(error_context, action: action_class) do
          # Guarded by the same best_effort boundary as everything else in this block: a custom
          # logger's severity predicate can itself raise, and that must be absorbed exactly like any
          # other formatting failure here — some callers (call_async's invocation log, the
          # enqueue-all completion log) invoke log_at_level with no other best_effort wrapping it, so
          # checking the predicate outside this boundary could abort the call it only meant to log.
          next unless would_log?(level)

          # Prepare and format context if needed
          context_str = if context_instance && context_direction
                          # Instance-level: use private inputs_for_logging / outputs_for_logging
                          data = case context_direction
                                 when :inbound then ActionState.inputs_for_logging(context_instance)
                                 when :outbound then ActionState.outputs_for_logging(context_instance)
                                 end
                          format_context(data)
                        elsif context_data && context_direction
                          # Class-level: use internal _context_slice
                          data = action_class._context_slice(data: context_data, direction: context_direction)
                          format_context(data)
                        end

          # Add context to message parts if present
          full_message_parts = context_str ? message_parts + [context_str] : message_parts
          message = full_message_parts.compact.join(join_string)

          # Annotate with resolved tag/dimension facets: structured named tags when the configured
          # logger is a SemanticLogger (legible as log fields / Datadog facets), otherwise a readable
          # suffix on the plain line. Mutually exclusive — semantic_logger's own formatter renders the
          # named tags, so the suffix would be redundant there.
          named_tags = facets ? Axn::Core::Tagging.namespaced(tags: facets[:tags] || {}, dimensions: facets[:dimensions] || {}) : {}

          # `log`, not `public_send(level, ...)`: `Core::Flow::Messages::ClassMethods` also defines
          # a same-named `error` (and `success`) class method for declaring custom messages, and it
          # wins method resolution over `Core::Logging`'s convenience methods of the same name.
          if named_tags.any? && semantic_logger?
            SemanticLogger.tagged(**named_tags) do
              action_class.log(message, level:, before:, after:, prefix:)
            end
          else
            message += facet_suffix(facets) if named_tags.any?
            action_class.log(message, level:, before:, after:, prefix:)
          end
        end
      end

      # True only when the logger that will actually emit is a SemanticLogger — merely having the
      # gem loaded isn't enough, since its thread-local tagged context is read only by SemanticLogger
      # instances (see design: gating on the configured logger avoids facets vanishing from a line
      # emitted by a plain Logger). Public so the Executor can gate the in-flight body context on it,
      # from `with_facet_log_context`, which wraps the action BODY — so answering this by raising
      # would abort `.call` before the body runs over a question about how to format a log line. A
      # seam that cannot answer means NOT SemanticLogger, the same asymmetry `Extensions.raises_in_dev?`
      # takes: a wrong `false` costs structured tags on a log line, a raise costs the whole call. Reads
      # `Axn.config.logger` through `Identity.kind?` rather than dispatching `is_a?` on it, on the same
      # terms as the ActiveRecord::Relation check below.
      def semantic_logger?
        defined?(SemanticLogger::Logger) && Axn::Internal::Identity.kind?(Axn.config.logger, SemanticLogger::Logger)
      rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR
        false
      end

      # Whether the configured logger would actually emit at `level`, read via the logger's OWN
      # severity predicate (`debug?`/`info?`/`warn?`/`error?`/`fatal?` — the same query Ruby's stdlib
      # `Logger` and `SemanticLogger::Logger` already expose). A logger that doesn't respond to the
      # predicate is assumed to emit, which matches today's behavior exactly — a custom logger
      # implementing only the plain level methods loses nothing. This is deliberately NOT a switch to
      # block-form logging (`logger.info { msg }`): that would silently drop the message for a custom
      # logger whose level methods take a positional argument only and ignore an unused block. Public:
      # both `log_at_level` and the Executor's before/after hooks call this (PRO-3335), so it is called
      # up to twice per emitted line — `LEVEL_PREDICATES` is precomputed rather than interpolating
      # `:"#{level}?"` fresh each time for exactly that reason (see its own comment). An undeclared
      # level (never happens today; `Core::Logging::LEVELS` is the only source of one) falls back to
      # the dynamic form rather than raising, so a future level addition here fails open, not loud.
      def would_log?(level)
        logger = Axn.config.logger
        predicate = LEVEL_PREDICATES[level] || :"#{level}?"
        !logger.respond_to?(predicate) || logger.public_send(predicate)
      end

      private

      # Labeled readable suffix for the plain line, each group rendered with the same
      # format_object + MAX_CONTEXT_LENGTH truncation as inbound/outbound context. An empty
      # (or absent) group is omitted entirely.
      def facet_suffix(facets)
        return "" unless facets

        %i[tags dimensions].filter_map do |key|
          formatted = format_context(facets[key])
          " [#{key}: #{formatted}]" if formatted
        end.join
      end

      # Formats context data for logging, with truncation if needed
      def format_context(data)
        return unless data.present?

        formatted = format_object(data)
        return formatted if formatted.length <= MAX_CONTEXT_LENGTH

        formatted[0, MAX_CONTEXT_LENGTH - TRUNCATION_SUFFIX.length] + TRUNCATION_SUFFIX
      end

      # Formats an object for logging, handling special cases for ActiveRecord and ActionController::Parameters.
      # `seen` carries the containers open on the current path (see CycleGuard) so a self-referential
      # Hash/Array renders the way Ruby's own #inspect renders one instead of recursing until the
      # stack blows — a log line must never be able to take down the call it is describing.
      def format_object(data, seen = nil)
        case data
        when Hash
          CycleGuard.guard(data, seen, on_cycle: CycleGuard::HASH_PLACEHOLDER) do |nested|
            # NOTE: slightly more manual in order to avoid quotes around ActiveRecord objects' <Class#id> formatting
            # Keys are rendered through the shared label rather than interpolated: caller data can carry keys in
            # two different non-ASCII encodings, and joining those raised Encoding::CompatibilityError from the
            # log line itself — which the side channel then swallowed, losing the line entirely. Values carry
            # the same risk and are guarded the same way, at their source below — see the `else` branch.
            #
            # Built with `<<`, not `.map { ... }.join(', ')`: `<<` copies its argument's bytes into `buf`
            # IMMEDIATELY, at the point of the call — before the NEXT fragment is even computed — whereas
            # `.map` collects every fragment first and `.join` copies them only at the very end. That
            # distinction is what makes it safe for a fragment to be a BORROWED rendering (see
            # `Text.borrowed`, `PropertyNames.renderable_label`'s Symbol fast path): a later sibling's
            # `#inspect` mutating an earlier one's returned String in place (verified: it silently swaps
            # in the mutated bytes, or raises `Encoding::CompatibilityError` composing next to a
            # genuinely non-ASCII sibling — PRO-3335 review) can't reach bytes `<<` already copied.
            buf = +"{"
            data.each_with_index do |(k, v), i|
              buf << ", " if i.positive?
              buf << Axn::Internal::Reflection::PropertyNames.renderable_label(k) << ": " << format_object(v, nested)
            end
            buf << "}"
          end
        when Array
          CycleGuard.guard(data, seen, on_cycle: CycleGuard::ARRAY_PLACEHOLDER) do |nested|
            # Composed into a String here, like the Hash branch above — NOT left as an Array for the
            # parent to interpolate. An Array handed to `#{}` renders via Array#to_s (== #inspect),
            # which re-inspects each already-formatted child String, escaping its quotes/backslashes
            # again. Left uncomposed, that re-escaping compounds once per nesting level, making both
            # the render cost and the emitted line's length exponential in nesting depth (PRO-3203).
            #
            # `<<` per element, not `.map { ... }.join(', ')` — same reason as the Hash branch above.
            buf = +"["
            data.each_with_index do |v, i|
              buf << ", " if i.positive?
              buf << format_object(v, nested)
            end
            buf << "]"
          end
        else
          # The conversion walks and rebuilds the structure itself, so a cycle nested inside raises
          # before the guard above could see the repeated container — attempt it and fall back. Returned
          # RAW (a Hash, not a String): every other branch below ends in a String that a Hash/Array
          # ancestor's `.join` above may compose with a sibling, so each of THOSE is rendered through the
          # shared UTF-8-safe renderer; this one embeds by the caller's `#{}`/`to_s`, and `Hash#inspect`
          # already escapes non-ASCII bytes in each of its own values, same as `String#inspect` does.
          is_params = defined?(ActionController::Parameters) && data.is_a?(ActionController::Parameters)
          return CycleGuard.converted_or_placeholder { data.to_unsafe_h } if is_params

          if defined?(ActiveRecord::Base) && data.is_a?(ActiveRecord::Base)
            id = Axn::Internal::Text.borrowed(data.to_param.presence || "unpersisted")
            return "<#{Axn::Internal::Rendering.class_name(data)}##{id}>"
          end

          # A RELATION is named rather than inspected, for the same reason `facade_inspector` names one:
          # `Relation#inspect` runs the query. The difference is what it costs here — that inspector only runs
          # when something asks for one, while this runs on EVERY logged call, so an action exposing a
          # relation issued a SELECT per call purely to build its log line.
          #
          # `Rendering.class_name` is UTF-8-safe on its own (it delegates to `RenderedClassName`, which
          # renders a foreign constant path through the same shared renderer used below) — the AR::Base
          # branch above uses it too, rather than `data.class.name`, for the same reason: ActiveRecord
          # overrides `Class#name` on a relation's generated class to answer `"ActiveRecord::Relation"`,
          # which would lose the model.
          is_relation = defined?(ActiveRecord::Relation) && Axn::Internal::Identity.kind?(data, ActiveRecord::Relation)
          return Axn::Internal::Rendering.class_name(data) if is_relation

          # Through the shared renderer, not the raw `inspect`: a leaf can be any caller object, and one
          # whose own `#inspect` returns non-ASCII bytes in a foreign encoding would otherwise sit in this
          # value unguarded until a sibling leaf elsewhere in the same structure turns up a SECOND foreign
          # encoding for a `.join` above to collide with — raising Encoding::CompatibilityError out of the
          # log line itself (or losing it entirely, swallowed by the best_effort boundary around this whole
          # call). Renders byte-identical for ASCII/valid-UTF-8 (the overwhelming case), transcodes a
          # legible foreign encoding, and escapes only bytes with no UTF-8 rendering at all.
          #
          # `borrowed`, not `renderable`: composed into the buffer above IMMEDIATELY (see the Hash/Array
          # branches' own comments — the ordering is what makes this safe) and dropped once the line is
          # emitted, so it never needs its own owned copy (PRO-3335).
          Axn::Internal::Text.borrowed(data.inspect)
        end
      end
    end
  end
end
