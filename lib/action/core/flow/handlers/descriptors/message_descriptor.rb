# frozen_string_literal: true

require "action/core/flow/handlers/base_descriptor"

module Action
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            attr_reader :prefix

            def initialize(matcher:, handler:, prefix: nil)
              super(matcher:, handler:)
              @prefix = prefix
            end
          end
        end
      end
    end
  end
end
