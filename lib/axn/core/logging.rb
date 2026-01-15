# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Axn
  module Core
    module Logging
      LEVELS = %i[debug info warn error fatal].freeze

      def self.included(base)
        base.class_eval do
          extend ClassMethods
          delegate :log, *LEVELS, to: :class
        end
      end

      module ClassMethods
        def log_level = Axn.config.log_level

        # @param message [String] The message to log
        # @param level [Symbol] The log level (default: log_level)
        # @param before [String, nil] Text to prepend to the message
        # @param after [String, nil] Text to append to the message
        # @param prefix [String, nil] Override the default prefix (useful for class-level logging)
        def log(message, level: log_level, before: nil, after: nil, prefix: nil)
          resolved_prefix = prefix.nil? ? _log_prefix : prefix
          msg = [resolved_prefix, message].compact_blank.join(" ")
          msg = [before, msg, after].compact_blank.join if before || after

          Axn.config.logger.send(level, msg)
        end

        LEVELS.each do |level|
          define_method(level) do |message, before: nil, after: nil, prefix: nil|
            log(message, level:, before:, after:, prefix:)
          end
        end

        def _log_prefix
          names = NestingTracking._current_axn_stack.map do |axn|
            axn.class.name.presence || "Anonymous Class"
          end
          "[#{names.join(' > ')}]"
        end
      end
    end
  end
end
