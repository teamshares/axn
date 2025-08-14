# frozen_string_literal: true

require "action/core/flow/handlers/matcher"

module Action
  module Core
    module Flow
      # "Handlers" doesn't feel like *quite* the right name for this, but basically things in this namespace
      # relate to conditionally-invoked code blocks (e.g. callbacks, messages, etc.)
      module Handlers
        class BaseHandler
          def initialize(matcher: nil)
            @matcher = matcher.nil? ? nil : Matcher.new(matcher)
          end

          def matches?(action:, exception:)
            return true if @matcher.nil?

            @matcher.call(exception:, action:)
          end

          # Subclasses should implement `apply(action:, exception:)`
        end
      end
    end
  end
end
