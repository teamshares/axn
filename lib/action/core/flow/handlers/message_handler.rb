# frozen_string_literal: true

require "action/core/flow/handlers/base_handler"
require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        class MessageHandler < BaseHandler
          def initialize(matcher:, handler:, prefix: nil)
            super(matcher:, handler:)
            @prefix = prefix
          end

          # Returns a string (truthy) when it applies and yields a non-blank message; otherwise nil
          def apply(action:, exception:)
            return nil unless matches?(action:, exception:)

            # If we have a prefix but no handler, fall back to exception message
            if @prefix && !handler
              return "#{@prefix}#{exception.message}" if exception

              return nil
            end

            value =
              if handler.is_a?(Symbol) || handler.respond_to?(:call)
                Invoker.call(action:, handler:, exception:, operation: "determining message callable")
              else
                handler
              end

            message = value.respond_to?(:presence) ? value.presence : value
            return message unless @prefix && message.present?

            # Apply prefix to the custom message
            "#{@prefix}#{message}"
          end

          private

          attr_reader :prefix
        end
      end
    end
  end
end
