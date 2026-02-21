# frozen_string_literal: true

module Axn
  module Core
    module AutomaticLogging
      def self.included(base)
        base.class_eval do
          extend ClassMethods

          # Single class_attribute - nil means disabled, any level means enabled
          class_attribute :log_calls_level, default: Axn.config.log_level
          class_attribute :log_errors_level, default: nil
        end
      end

      module ClassMethods
        def log_calls(level)
          self.log_calls_level = level.presence
        end

        def log_errors(level)
          self.log_errors_level = level.presence
        end
      end
    end
  end
end
