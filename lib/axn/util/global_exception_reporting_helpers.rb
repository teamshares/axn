# frozen_string_literal: true

module Axn
  module Util
    # Internal utilities for formatting context data for global exception reporting.
    # These methods are used by the exception handling system to prepare context
    # for error tracking services (e.g., Honeybadger, Sentry).
    module GlobalExceptionReportingHelpers
      class << self
        # Format hash values for error tracking systems (recursive).
        # Converts complex objects (ActiveRecord models, ActionController::Parameters, FormObjects)
        # into serializable formats suitable for logging and error tracking.
        # Nested hashes and arrays are traversed and their values formatted as well.
        #
        # @param hash [Hash] The hash to format
        # @return [Hash] A new hash with formatted values
        #
        # @example
        #   formatted = Axn::Util::GlobalExceptionReportingHelpers.format_hash_values({
        #     user: User.find(123),
        #     params: ActionController::Parameters.new(name: "Alice")
        #   })
        #   # => { user: "gid://app/User/123", params: { name: "Alice" } }
        def format_hash_values(hash)
          hash.transform_values { |v| format_value(v) }
        end

        # Format a single value for retry command generation.
        # Produces copy-pasteable Ruby code for reproducing the action call.
        #
        # @param value [Object] The value to format
        # @return [String] Ruby code representation of the value
        #
        # @example
        #   Axn::Util::GlobalExceptionReportingHelpers.format_value_for_retry_command(User.find(123))
        #   # => "User.find(123)"
        #
        #   Axn::Util::GlobalExceptionReportingHelpers.format_value_for_retry_command("gid://app/User/123")
        #   # => "User.find(123)"
        #
        #   Axn::Util::GlobalExceptionReportingHelpers.format_value_for_retry_command("Alice")
        #   # => "\"Alice\""
        def format_value_for_retry_command(value)
          # Handle ActiveRecord model instances
          if value.respond_to?(:to_global_id) && value.respond_to?(:id) && !value.is_a?(Class)
            begin
              model_class = value.class.name
              id = value.id
              return "#{model_class}.find(#{id.inspect})"
            rescue StandardError
              # If accessing id fails, fall through to default behavior
            end
          end

          # Handle GlobalID strings (useful for serialized values)
          if value.is_a?(String) && value.start_with?("gid://")
            begin
              gid = GlobalID.parse(value)
              if gid
                model_class = gid.model_class.name
                id = gid.model_id
                return "#{model_class}.find(#{id.inspect})"
              end
            rescue StandardError
              # If parsing fails, fall through to default behavior
            end
          end

          # Default: use inspect for other types
          value.inspect
        end

        # Generate a retry command for an action.
        # Creates copy-pasteable Ruby code that can be used to reproduce the action call.
        #
        # @param action [Axn::Core] The action instance
        # @param context [Hash] The context hash (typically the raw inputs, not yet formatted)
        # @return [String, nil] The retry command, or nil if action name is unavailable
        #
        # @example
        #   Axn::Util::GlobalExceptionReportingHelpers.retry_command(
        #     action: update_user_action,
        #     context: { user: User.find(123), name: "Alice" }
        #   )
        #   # => "UpdateUser.call(user: User.find(123), name: \"Alice\")"
        def retry_command(action:, context:)
          action_name = action.class.name
          return nil if action_name.nil? # Anonymous (unnamed) actions cannot generate a retry command

          expected_fields = action.internal_field_configs.map(&:field)

          return "#{action_name}.call()" if expected_fields.empty?

          args = expected_fields.map do |field|
            value = context[field]

            "#{field}: #{format_value_for_retry_command(value)}"
          end.join(", ")

          "#{action_name}.call(#{args})"
        end

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
        #     retry_command: "...",         # Optional: copy-pasteable retry command (if _include_retry_command_in_exceptions is true)
        #     current_attributes: { ... },  # Optional: Current.attributes if defined and present
        #     async: { ... }                # Optional: async retry context if applicable
        #   }
        #
        # @example
        #   context = Axn::Util::GlobalExceptionReportingHelpers.build_exception_context(
        #     action: update_user_action,
        #     retry_context: nil
        #   )
        #   # => { inputs: { user_id: 123, name: "Alice" }, outputs: {}, current_attributes: { request_id: "abc" } }
        def build_exception_context(action:, retry_context: nil)
          # Get structured execution context (inputs, outputs, and extra keys at top level)
          exec_ctx = action.execution_context
          raw_inputs = exec_ctx[:inputs]

          # Start building the context with formatted execution context
          context = {
            inputs: format_hash_values(raw_inputs),
            outputs: format_hash_values(exec_ctx[:outputs] || {}),
          }

          # Add any extra keys from execution context (from set_execution_context / hook)
          extra_keys = exec_ctx.except(:inputs, :outputs)
          context.merge!(format_hash_values(extra_keys)) if extra_keys.any?

          # Add async information if available
          context[:async] = retry_context.to_h if retry_context

          # Auto-generate retry command if experimental flag is enabled
          if Axn.config._include_retry_command_in_exceptions
            # Use raw_inputs (not formatted) for retry command generation
            # so we can generate proper Model.find() calls from AR objects
            context[:retry_command] = retry_command(
              action:,
              context: raw_inputs,
            )
          end

          # Auto-include Current.attributes if defined, responds to attributes, and has non-nil values
          if defined?(Current) && Current.respond_to?(:attributes)
            current_attrs = Current.attributes
            # Only include if the hash has any non-nil values
            context[:current_attributes] = format_hash_values(current_attrs) if current_attrs.present? && current_attrs.any? { |_k, v| !v.nil? }
          end

          context
        end

        private

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
            value.to_global_id.to_s
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
