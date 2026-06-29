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

            attr_reader :join

            def initialize(matcher:, handler:, prefixed: false, join: nil)
              @prefixed = prefixed
              @join = join
              super(matcher:, handler:)
            end

            def prefixed? = @prefixed

            # Raise for any removed option (with its migration hint) or otherwise-unknown option,
            # rather than silently dropping it.
            def self.reject_unsupported_options!(options)
              return if options.empty?

              # Prefer a removed-option migration hint (most actionable); otherwise surface ALL unknown
              # keys at once so the caller fixes them in one pass rather than one error at a time.
              removed = options.keys & REMOVED_OPTION_MESSAGES.keys
              raise ArgumentError, REMOVED_OPTION_MESSAGES.fetch(removed.first) if removed.any?

              keys = options.keys.map(&:inspect).join(", ")
              label = options.size == 1 ? "Unknown #{keys} option" : "Unknown options #{keys}"
              raise ArgumentError, "#{label} for error/success message"
            end

            def self.build(handler: nil, if: nil, unless: nil, prefixed: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              prefixed = !matcher.static? if prefixed.nil?

              # join: (a String separator or a ->(base, reason) {} Proc) is how a base combines with its
              # reasons, so it only belongs on the base — an unconditional, non-prefixed headline.
              # Anything conditional or prefixed is a reason, so reject join: there rather than ignore it.
              base = matcher.static? && !prefixed
              raise ArgumentError, "join: only applies to the base (an unprefixed headline)" if join && !base
              raise ArgumentError, "join: must be a String or a callable ->(base, reason) {}" if join && !(join.is_a?(String) || join.respond_to?(:call))

              new(handler:, prefixed:, join:, matcher:)
            end
          end
        end
      end
    end
  end
end
