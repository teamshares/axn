# frozen_string_literal: true

require "axn/core/flow/handlers/base_descriptor"

module Axn
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            # Options removed in the nested-error-semantics change, mapped to the actionable
            # migration hint. Enforced here (the construction chokepoint) so the direct/Factory
            # `build` path raises the same hint the `error`/`success` DSL does — never a silent ignore.
            REMOVED_OPTION_MESSAGES = {
              from: "from: is no longer supported — run the child with `call` and " \
                    '`fail!("context: #{result.error}") unless result.ok?`',
              prefix: "prefix: is no longer supported — declare a base `error \"…\"` " \
                      "(prefixes reasons by default; opt out with prefixed: false)",
            }.freeze

            attr_reader :delimiter

            def initialize(matcher:, handler:, prefixed: false, delimiter: nil)
              @prefixed = prefixed
              @delimiter = delimiter
              super(matcher:, handler:)
            end

            def prefixed? = @prefixed

            # A dynamic handler (block/lambda/symbol) resolves a message at runtime; a literal (String)
            # handler is a fixed headline. Used to tell a base ("headline") from a reason.
            def dynamic_handler? = self.class.dynamic_handler?(handler)

            def self.dynamic_handler?(handler) = handler.is_a?(Symbol) || handler.respond_to?(:call)

            # Raise for any removed option (with its migration hint) or otherwise-unknown option,
            # rather than silently dropping it.
            def self.reject_unsupported_options!(options)
              return if options.empty?

              key = options.keys.first
              raise ArgumentError, REMOVED_OPTION_MESSAGES.fetch(key) { "Unknown #{key.inspect} option for error/success message" }
            end

            def self.build(handler: nil, if: nil, unless: nil, prefixed: nil, delimiter: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # Match the DSL default ("conditional/dynamic reasons are prefixed by default") so the
              # prebuilt/Factory path behaves like `error … if:`. Explicit prefixed: still wins.
              prefixed = !matcher.static? || dynamic_handler?(handler) if prefixed.nil?

              new(handler:, prefixed:, delimiter:, matcher:)
            end
          end
        end
      end
    end
  end
end
