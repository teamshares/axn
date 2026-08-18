# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Axn
  module Core
    module Logging
      LEVELS = %i[debug info warn error fatal].freeze

      # In a module rather than stamped onto the action class, so a user who wants to wrap one of
      # these (to prefix every message, say) can `def log` and reach axn's via `super` — and so a user
      # who takes the name outright loses only the helper. Internals never come through here.
      module InstanceMethods
        delegate :log, *LEVELS, to: :class
      end

      def self.included(base)
        base.class_eval do
          extend ClassMethods
          include InstanceMethods
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

        # Private because an `_`-prefixed name in a module extended onto every action class otherwise lands
        # there as a PUBLIC singleton method, so the convention and the surface disagree. Reached only from
        # `log` above, with an implicit receiver.
        private

        def _log_prefix
          names = NestingTracking._current_axn_stack.map do |axn|
            axn.class.resolved_axn_name
          end
          "[#{names.join(' > ')}]"
        end
      end
    end
  end
end
