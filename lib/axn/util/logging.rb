# frozen_string_literal: true

module Axn
  module Util
    module Logging
      extend self

      MAX_CONTEXT_LENGTH = 150
      TRUNCATION_SUFFIX = "…<truncated>…"

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
          "{#{data.map { |k, v| "#{k}: #{format_object(v)}" }.join(", ")}}"
        when Array
          data.map { |v| format_object(v) }
        else
          return data.to_unsafe_h if defined?(ActionController::Parameters) && data.is_a?(ActionController::Parameters)
          return "<#{data.class.name}##{data.to_param.presence || "unpersisted"}>" if defined?(ActiveRecord::Base) && data.is_a?(ActiveRecord::Base)

          data.inspect
        end
      end

      # Prepares context data for logging from a class-level context (e.g., async invocation)
      # This handles the concern leakage by properly calling the class-level context_for_logging method
      def prepare_context_for_logging(action_class, data:, direction:)
        action_class.context_for_logging(data:, direction:)
      end
    end
  end
end

