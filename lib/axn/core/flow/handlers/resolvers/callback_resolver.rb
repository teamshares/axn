# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"

module Axn
  module Core
    module Flow
      module Handlers
        module Resolvers
          # Internal: resolves and executes callbacks
          class CallbackResolver < BaseResolver
            def execute_callbacks
              matching_entries.each do |descriptor|
                execute_callback(descriptor)
              end
            end

            private

            # Executes a specific callback descriptor
            def execute_callback(descriptor)
              Invoker.call(operation: "executing callback", action:, handler: descriptor.handler, exception:)
            end
          end
        end
      end
    end
  end
end
