# frozen_string_literal: true

require "axn/core/flow/handlers/base_descriptor"
require "axn/core/flow/handlers/invoker"

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

            # Delegate to Invoker so "is this a reason vs the base headline?" uses the SAME test as
            # "how is this handler dispatched?" — a callable that Invoker would treat as a literal
            # (e.g. responds to #call but not #arity) must not be misclassified as a dynamic reason.
            def self.dynamic_handler?(handler) = Invoker.dynamic?(handler)

            # Raise for any removed option (with its migration hint) or otherwise-unknown option,
            # rather than silently dropping it.
            def self.reject_unsupported_options!(options)
              return if options.empty?

              key = options.keys.first
              raise ArgumentError, REMOVED_OPTION_MESSAGES.fetch(key) { "Unknown #{key.inspect} option for error/success message" }
            end

            # Validate the prefixed:/delimiter: combination against whether this entry is a "reason"
            # (conditional or dynamic) vs the base headline. Enforced in `build` (the chokepoint) so
            # the direct/Factory path fails at declaration exactly like the `error`/`success` DSL —
            # e.g. `delimiter:` on a conditional reason raises instead of being silently ignored.
            def self.reject_invalid_prefixing!(prefixed:, delimiter:, reason:)
              raise ArgumentError, "prefixed: true requires a condition (if:/unless:) or a dynamic message" if prefixed && !reason
              raise ArgumentError, "delimiter: only applies to a base error message" if delimiter && reason
            end

            def self.build(handler: nil, if: nil, unless: nil, prefixed: nil, delimiter: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # A "reason" is conditional or dynamic; the base is a static literal. Validate the
              # prefixing options against that, then default prefixed: to match the DSL ("reasons are
              # prefixed by default"). Explicit prefixed: still wins.
              reason = !matcher.static? || dynamic_handler?(handler)
              reject_invalid_prefixing!(prefixed:, delimiter:, reason:)
              prefixed = reason if prefixed.nil?

              new(handler:, prefixed:, delimiter:, matcher:)
            end
          end
        end
      end
    end
  end
end
