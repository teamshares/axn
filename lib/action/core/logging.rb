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
      def log(message, level: :info)
        level = :info if level == :debug && _targeted_for_debug_logging?
        msg = [_log_prefix, message].compact_blank.join(" ")

        Action.config.logger.send(level, msg)
      end

      LEVELS.each do |level|
        define_method(level) do |message|
          log(message, level:)
        end
      end

      # TODO: this is ugly, we should be able to override in the config class...
      def _log_prefix = name == "Action::Configuration" ? nil : "[#{name || "Anonymous Class"}]"

      def _targeted_for_debug_logging?
        return true if Action.config.global_debug_logging?

        target_class_names = (ENV["SA_DEBUG_TARGETS"] || "").split(",").map(&:strip)
        target_class_names.include?(name)
      end
    end
  end
end
