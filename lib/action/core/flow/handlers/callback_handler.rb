# frozen_string_literal: true

require "action/core/flow/handlers/base_handler"
require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        class CallbackHandler < BaseHandler
          def apply(action:, exception:)
            return false unless matches?(action:, exception:)

            Invoker.call(action:, handler:, exception:, operation: "executing handler")
            true
          end
        end
      end
    end
  end
end
