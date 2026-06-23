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

            def self.build(handler: nil, if: nil, unless: nil, prefixed: nil, delimiter: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # Conditionality picks the default role: a conditional entry (if:/unless:) is a prefixed
              # *reason*; an unconditional entry is the *headline* (base). `prefixed:` overrides
              # explicitly — `prefixed: true` promotes an unconditional entry to a prefixed reason.
              # Whether the handler is a literal, block, or symbol carries no meaning here (a block is
              # just a headline/reason whose text is computed at runtime).
              prefixed = !matcher.static? if prefixed.nil?

              # delimiter: is the string a base joins its reasons with, so it only belongs on the
              # base/headline — never on a reason. Enforced in `build` (the chokepoint) so the
              # direct/Factory path fails at declaration exactly like the `error`/`success` DSL.
              raise ArgumentError, "delimiter: only applies to the base (an unprefixed headline)" if delimiter && prefixed

              new(handler:, prefixed:, delimiter:, matcher:)
            end
          end
        end
      end
    end
  end
end
