# frozen_string_literal: true

module Action
  module Core
    module Flow
      module Handlers
        module Resolvers
          class BaseResolver
            def initialize(registry, event_type, action:, exception:)
              @registry = registry
              @event_type = event_type
              @action = action
              @exception = exception
            end

            protected

            attr_reader :registry, :event_type, :action, :exception

            def candidate_entries = registry.for(event_type)
            def matching_entries = candidate_entries.select { |descriptor| descriptor.matches?(action:, exception:) }
          end
        end
      end
    end
  end
end
