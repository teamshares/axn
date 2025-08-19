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

            # Returns true if this descriptor has a prefix but no handler
            def prefix_only? = prefix.present? && handler.nil?

            # Returns true if this descriptor has both a prefix and a handler
            def has_prefix_and_handler? = prefix.present? && handler.present?

            # Returns true if this descriptor has no prefix and no handler (core default)
            def core_default? = prefix.nil? && handler.nil?

            # Returns the message type for this descriptor
            def message_type
              return :prefix_only if prefix_only?
              return :with_prefix if has_prefix_and_handler?
              return :core_default if core_default?

              :standard
            end
          end
        end
      end
    end
  end
end
