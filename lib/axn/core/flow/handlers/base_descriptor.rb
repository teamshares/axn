# frozen_string_literal: true

require "axn/core/flow/handlers/matcher"

module Axn
  module Core
    module Flow
      # "Handlers" doesn't feel like *quite* the right name for this, but basically things in this namespace
      # relate to conditionally-invoked code blocks (e.g. callbacks, messages, etc.)
      module Handlers
        class BaseDescriptor
          def initialize(matcher: nil, handler: nil)
            @matcher = matcher
            @handler = handler
            freeze
          end

          attr_reader :handler, :matcher

          def static? = @matcher.nil? || @matcher.static?

          def matches?(action:, exception:)
            return true if static?

            @matcher.call(exception:, action:)
          end

          def self.build(handler: nil, if: nil, unless: nil, **)
            matcher = Matcher.build(if:, unless:)
            new(matcher:, handler:)
          end
        end
      end
    end
  end
end
