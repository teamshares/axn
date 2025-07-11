# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Action
  module Logging
    LEVELS = %i[debug info warn error fatal].freeze

    def self.included(base)
      base.class_eval do
        extend ClassMethods
        delegate :log, *LEVELS, to: :class
      end
    end

    module ClassMethods
      def default_log_level = Action.config.default_log_level

      def log(message, level: default_log_level)
        msg = [_log_prefix, message].compact_blank.join(" ")

        Action.config.logger.send(level, msg)
      end

      LEVELS.each do |level|
        define_method(level) do |message|
          log(message, level:)
        end
      end

      def _log_prefix = "[#{name.presence || "Anonymous Class"}]"
    end
  end
end
