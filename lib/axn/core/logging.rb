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

        def log(message, level: log_level, before: nil, after: nil)
          msg = [_log_prefix, message].compact_blank.join(" ")
          msg = [before, msg, after].compact_blank.join if before || after

          Axn.config.logger.send(level, msg)
        end

        LEVELS.each do |level|
          define_method(level) do |message, before: nil, after: nil|
            log(message, level:, before:, after:)
          end
        end

        def _log_prefix = "[#{name.presence || "Anonymous Class"}]"
      end
    end
  end
end
