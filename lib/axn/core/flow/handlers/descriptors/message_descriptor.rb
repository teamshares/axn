# frozen_string_literal: true

require "axn/core/flow/handlers/base_descriptor"

module Axn
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            attr_reader :delimiter

            def initialize(matcher:, handler:, prefixed: false, delimiter: nil)
              @prefixed = prefixed
              @delimiter = delimiter
              super(matcher:, handler:)
            end

            def prefixed? = @prefixed

            def self.build(handler: nil, if: nil, unless: nil, prefixed: false, delimiter: nil, **)
              new(
                handler:,
                prefixed:,
                delimiter:,
                matcher: Matcher.build(if:, unless:),
              )
            end
          end
        end
      end
    end
  end
end
