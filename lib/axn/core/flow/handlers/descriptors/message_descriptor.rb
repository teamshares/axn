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

            # Raise for any removed option (with its migration hint) or otherwise-unknown option,
            # rather than silently dropping it.
            def self.reject_unsupported_options!(options)
              return if options.empty?

              key = options.keys.first
              raise ArgumentError, REMOVED_OPTION_MESSAGES.fetch(key) { "Unknown #{key.inspect} option for error/success message" }
            end

            def self.build(handler: nil, if: nil, unless: nil, prefixed: false, delimiter: nil, **unsupported)
              reject_unsupported_options!(unsupported)

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
