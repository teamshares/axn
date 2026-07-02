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
        def format_hash_values(hash)
          hash.transform_values { |v| format_value(v) }
        end

        # Recursively format a single value (Hash, Array, or scalar/complex object).
        def format_value(value)
          case value
          when Hash
            format_hash_values(value)
          when Array
            value.map { |item| format_value(item) }
          else
            format_single_value(value)
          end
        end

        # Format a single non-container value for error tracking.
        def format_single_value(value)
          if value.respond_to?(:to_global_id)
            begin
              value.to_global_id.to_s
            rescue ::URI::GID::MissingModelIdError
              "#<#{value.class.name} (unpersisted)>"
            end
          elsif defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)
            format_hash_values(value.to_unsafe_h)
          elsif value.is_a?(Axn::FormObject)
            format_hash_values(value.to_h)
          else
            value
          end
        end
      end
    end
  end
end
