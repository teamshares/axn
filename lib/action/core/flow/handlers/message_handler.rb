# frozen_string_literal: true

require "action/core/flow/handlers/base_handler"
require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        class MessageHandler < BaseHandler
          def initialize(matcher:, message:, static: false)
            @message = message
            @static = !!static
            super(matcher:)
          end

          attr_reader :message

          def static? = @static

          def matches?(action:, exception:)
            return true if static?

            super
          end

          # Returns a string (truthy) when it applies and yields a non-blank message; otherwise nil
          def apply(action:, exception:)
            return nil unless matches?(action:, exception:)

            value =
              if message.is_a?(Symbol) || message.respond_to?(:call)
                Invoker.call_block(action:, block: message, exception:, operation: "determining message callable")
              else
                message
              end
            value.respond_to?(:presence) ? value.presence : value
          end
        end
      end
    end
  end
end
