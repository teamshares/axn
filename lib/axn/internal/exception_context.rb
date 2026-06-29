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
        # @return [Hash] Enhanced context with structure:
        #   {
        #     inputs: { ... },              # User's action inputs (filtered for sensitive data, always formatted)
        #     outputs: { ... },             # Action outputs (filtered for sensitive data, always formatted)
        #     ...extra_keys...,             # Additional context from set_execution_context / hook (formatted)
        #     current_attributes: { ... },  # Optional: Current.attributes if defined and present
        #     async: { ... }                # Optional: async retry context if applicable
        #   }
        def build(action:, retry_context: nil, axn_stack: nil)
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
          # user-facing result.error aggregation deliberately keeps out of the message. The caller
          # passes the snapshot captured at the innermost report (see ExceptionClassification.captured_stack)
          # so an ancestor-retried report keeps the full path even after inner frames have popped.
          # Omitted for a single (non-nested) action. :axn_stack is a RESERVED_EXECUTION_CONTEXT_KEY, so
          # this never clobbers a user-supplied value.
          context[:axn_stack] = axn_stack if axn_stack && axn_stack.length > 1

          # Add async information if available
          context[:async] = retry_context.to_h if retry_context

          # Auto-include Current.attributes if defined, responds to attributes, and has non-nil values
          if defined?(Current) && Current.respond_to?(:attributes)
            current_attrs = Current.attributes
            # Only include if the hash has any non-nil values
            context[:current_attributes] = format_hash_values(current_attrs) if current_attrs.present? && current_attrs.any? { |_k, v| !v.nil? }
          end

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
