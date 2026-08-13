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

            # Executes a specific callback descriptor.
            #
            # The operation names the PHASE (`executing on_success callback`), not just "a callback".
            # It is the whole description a reader gets — in the warning log and in the
            # `on_ignored_exception` report — and an on_success callback that silently didn't run means
            # something very different from an on_error one that didn't. `event_type` is the same symbol
            # the `on_<event>` DSL registered under, so the two always agree.
            def execute_callback(descriptor)
              Invoker.call(operation: "executing on_#{event_type} callback", action:, handler: descriptor.handler, exception:)
            end
          end
        end
      end
    end
  end
end
