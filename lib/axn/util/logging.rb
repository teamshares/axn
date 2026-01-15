# frozen_string_literal: true

module Axn
  module Util
    module Logging
      extend self

      MAX_CONTEXT_LENGTH = 150
      TRUNCATION_SUFFIX = "…<truncated>…"

      # Logs a message at the specified level with error handling
      # @param action_class [Class] The action class to log from
      # @param level [Symbol] The log level (e.g., :info, :warn)
      # @param message_parts [Array<String>] Parts of the message to join
      # @param error_context [String] Context for error reporting if logging fails
      # @param join_string [String] String to join message parts with
      # @param before [String, nil] Text to prepend to the message
      # @param after [String, nil] Text to append to the message
      # @param context_direction [Symbol, nil] Direction for context logging (:inbound or :outbound)
      # @param context_instance [Object, nil] Action instance for instance-level context_for_logging
      # @param context_data [Hash, nil] Raw data for class-level context_for_logging
      def log_at_level(
        action_class,
        level:,
        message_parts:,
        error_context:,
        join_string: " ",
        before: nil,
        after: nil,
        context_direction: nil,
        context_instance: nil,
        context_data: nil
      )
        return unless level

        # Prepare and format context if needed
        context_str = if context_instance && context_direction
                        # Instance-level context_for_logging
                        data = context_instance.context_for_logging(context_direction)
                        format_context(data)
                      elsif context_data && context_direction
                        # Class-level context_for_logging
                        data = action_class.context_for_logging(data: context_data, direction: context_direction)
                        format_context(data)
                      end

        # Add context to message parts if present
        full_message_parts = context_str ? message_parts + [context_str] : message_parts
        message = full_message_parts.compact.join(join_string)

        action_class.public_send(level, message, before:, after:)
      rescue StandardError => e
        Axn::Internal::Logging.piping_error(error_context, action: action_class, exception: e)
      end

      private

      # Formats context data for logging, with truncation if needed
      def format_context(data)
        return unless data.present?

        formatted = format_object(data)
        return formatted if formatted.length <= MAX_CONTEXT_LENGTH

        formatted[0, MAX_CONTEXT_LENGTH - TRUNCATION_SUFFIX.length] + TRUNCATION_SUFFIX
      end

      # Formats an object for logging, handling special cases for ActiveRecord and ActionController::Parameters
      def format_object(data)
        case data
        when Hash
          # NOTE: slightly more manual in order to avoid quotes around ActiveRecord objects' <Class#id> formatting
          "{#{data.map { |k, v| "#{k}: #{format_object(v)}" }.join(', ')}}"
        when Array
          data.map { |v| format_object(v) }
        else
          return data.to_unsafe_h if defined?(ActionController::Parameters) && data.is_a?(ActionController::Parameters)
          return "<#{data.class.name}##{data.to_param.presence || 'unpersisted'}>" if defined?(ActiveRecord::Base) && data.is_a?(ActiveRecord::Base)

          data.inspect
        end
      end
    end
  end
end
