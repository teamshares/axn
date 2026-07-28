# frozen_string_literal: true

module Axn
  module Internal
    # Builds context data for exception reporting to error tracking services
    # (e.g., Honeybadger, Sentry).
    module ExceptionContext
      class << self
        # Build enhanced context for global on_exception handler.
        # This method is called internally by Axn's exception handling system.
        #
        # @param action [Axn::Core] The action instance
        # @param retry_context [Axn::Async::RetryContext, nil] Optional async retry context
        # @param tags [Hash] Optional declared observability tags (attached verbatim, omitted if empty)
        # @param dimensions [Hash] Optional declared observability dimensions (attached verbatim, omitted if empty)
        # @return [Hash] Enhanced context with structure:
        #   {
        #     inputs: { ... },              # User's action inputs (filtered for sensitive data, always formatted)
        #     outputs: { ... },             # Action outputs (filtered for sensitive data, always formatted)
        #     ...extra_keys...,             # Additional context from set_execution_context / hook (formatted)
        #     ambient_context: { ... },     # Optional: declared, sensitive-filtered ambient_context if present
        #     async: { ... }                # Optional: async retry context if applicable
        #   }
        def build(action:, retry_context: nil, tags: {}, dimensions: {})
          # Get structured execution context (inputs, outputs, and extra keys at top level)
          exec_ctx = action.execution_context

          # Start building the context with formatted execution context
          context = {
            inputs: format_hash_values(exec_ctx[:inputs]),
            outputs: format_hash_values(exec_ctx[:outputs] || {}),
          }

          # Add any extra keys from execution context (from set_execution_context / hook)
          extra_keys = exec_ctx.except(:inputs, :outputs)
          context.merge!(format_hash_values(extra_keys)) if extra_keys.any?

          # When this ran nested inside other actions, record the call! chain (outermost → innermost)
          # so a report shows which path reached the failure — the structured breadcrumb the
          # user-facing result.error aggregation deliberately keeps out of the message. The live stack
          # is the full path here because the global report fires once, at the innermost action (which
          # is still on the stack). Omitted for a single (non-nested) action. :axn_stack is a
          # RESERVED_EXECUTION_CONTEXT_KEY, so this never clobbers a user-supplied value.
          stack = Core::NestingTracking._current_axn_stack
          context[:axn_stack] = stack.map { |a| a.class.resolved_axn_name } if stack.length > 1

          # Add async information if available
          context[:async] = retry_context.to_h if retry_context

          # Declared observability facets (PRO-2853), attached under reserved namespaced keys so a
          # consumer's on_exception can route tag → freeform extra, dimension → indexed tags. Values
          # arrive already coerced (Core::Tagging.coerce) and pre-duped (Core::Tagging.dup_facets) by
          # the Executor, so they are attached verbatim — NOT re-run through format_hash_values (which
          # would diverge from what the span/metrics observe) — and a handler mutating them can't
          # corrupt the memoized maps. Omitted when empty, mirroring the other optional keys above.
          context[:tags] = tags if tags.any?
          context[:dimensions] = dimensions if dimensions.any?

          context
        end

        private

        # Format hash values for error tracking systems (recursive).
        # Converts complex objects (ActiveRecord models, ActionController::Parameters, FormObjects)
        # into serializable formats suitable for logging and error tracking.
        def format_hash_values(hash, seen = nil)
          hash.transform_values { |v| format_value(v, seen) }
        end

        # Recursively format a single value (Hash, Array, or scalar/complex object). `seen` carries
        # the containers open on the current path (see CycleGuard): a self-referential value renders
        # as Ruby's #inspect placeholder rather than recursing until the stack blows, since building
        # a report must never be what kills the call whose exception it is reporting.
        def format_value(value, seen = nil)
          case value
          when Hash
            CycleGuard.guard(value, seen, on_cycle: CycleGuard::HASH_PLACEHOLDER) { |nested| format_hash_values(value, nested) }
          when Array
            CycleGuard.guard(value, seen, on_cycle: CycleGuard::ARRAY_PLACEHOLDER) { |nested| value.map { |item| format_value(item, nested) } }
          else
            format_single_value(value, seen)
          end
        end

        # Format a single non-container value for error tracking. The Parameters/FormObject branches
        # descend into a FRESHLY BUILT Hash (#to_unsafe_h / #to_h), whose identity differs on every
        # call — so the cycle guard keys on the SOURCE object, which is what actually recurs.
        def format_single_value(value, seen = nil)
          if value.respond_to?(:to_global_id)
            begin
              value.to_global_id.to_s
            rescue ::URI::GID::MissingModelIdError
              "#<#{value.class.name} (unpersisted)>"
            end
          elsif defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)
            convert_and_format(value, seen) { value.to_unsafe_h }
          elsif value.is_a?(Axn::FormObject)
            convert_and_format(value, seen) { value.to_h }
          else
            value
          end
        end

        # The conversion has to be attempted OUTSIDE the guard, because it walks the structure itself:
        # Parameters#to_unsafe_h recursively rebuilds every nested container, so a cycle in there raises
        # before the guard could see the repeated container. Losing this one value to a placeholder costs
        # a field in the report; letting it raise costs the ENTIRE report, since building context runs
        # inside the best-effort guard that reports the exception in the first place.
        def convert_and_format(value, seen, &)
          converted = CycleGuard.converted_or_placeholder(&)
          return converted if converted.equal?(CycleGuard::HASH_PLACEHOLDER)

          CycleGuard.guard(value, seen, on_cycle: CycleGuard::HASH_PLACEHOLDER) { |nested| format_hash_values(converted, nested) }
        end
      end
    end
  end
end
