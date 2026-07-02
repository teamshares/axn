# frozen_string_literal: true

module Axn
  module Internal
    # Logs action execution - handles building and emitting structured log
    # messages for action calls with context formatting and truncation.
    module CallLogger
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

        # Prepare and format context if needed
        context_str = if context_instance && context_direction
                        # Instance-level: use private inputs_for_logging / outputs_for_logging
                        data = case context_direction
                               when :inbound then context_instance.send(:inputs_for_logging)
                               when :outbound then context_instance.send(:outputs_for_logging)
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
        named_tags = facets ? facet_named_tags(facets) : {}

        if named_tags.any? && semantic_logger?
          SemanticLogger.tagged(**named_tags) do
            action_class.public_send(level, message, before:, after:, prefix:)
          end
        else
          message += facet_suffix(facets) if named_tags.any?
          action_class.public_send(level, message, before:, after:, prefix:)
        end
      rescue StandardError => e
        Axn::Internal::PipingError.swallow(error_context, action: action_class, exception: e)
      end

      private

      # True only when the logger that will actually emit is a SemanticLogger — merely having the
      # gem loaded isn't enough, since its thread-local tagged context is read only by SemanticLogger
      # instances (see design: gating on the configured logger avoids facets vanishing from a line
      # emitted by a plain Logger).
      def semantic_logger?
        defined?(SemanticLogger::Logger) && Axn.config.logger.is_a?(SemanticLogger::Logger)
      end

      # Flat, namespaced merge of both facet maps, mirroring the span-attribute convention
      # (axn.tag.<name> / axn.dimension.<name>) so the two namespaces never collide.
      def facet_named_tags(facets)
        named = {}
        facets[:tags]&.each { |name, value| named[:"axn.tag.#{name}"] = value }
        facets[:dimensions]&.each { |name, value| named[:"axn.dimension.#{name}"] = value }
        named
      end

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
