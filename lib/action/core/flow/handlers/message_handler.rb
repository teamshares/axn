# frozen_string_literal: true

require "action/core/flow/handlers/base_handler"
require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        class MessageHandler < BaseHandler
          # Returns a string (truthy) when it applies and yields a non-blank message; otherwise nil
          def apply(action:, exception:)
            return nil unless matches?(action:, exception:)

            value =
              if handler.is_a?(Symbol) || handler.respond_to?(:call)
                Invoker.call(action:, handler:, exception:, operation: "determining message callable")
              else
                handler
              end
            value.respond_to?(:presence) ? value.presence : value
          end
        end
      end
    end
  end
end
