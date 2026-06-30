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
                      "(attaches reasons by default; opt out with standalone: true)",
            }.freeze

            attr_reader :join

            def initialize(matcher:, handler:, standalone: false, join: nil)
              @standalone = standalone
              @join = join
              super(matcher:, handler:)
            end

            def standalone? = @standalone

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

            def self.build(handler: nil, if: nil, unless: nil, standalone: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # Default by conditionality: an unconditional entry is the standalone base headline; a
              # conditional entry is an attached reason. standalone: false on an unconditional entry
              # promotes it into an attached reason (renders under the base); standalone: true on a
              # conditional reason opts it out (renders on its own).
              standalone = matcher.static? if standalone.nil?

              # join: combines the base with its reasons, so it only belongs on the base — an
              # unconditional, standalone headline. A reason (conditional, or a promoted standalone:false
              # entry) is rejected rather than silently ignored.
              base = matcher.static? && standalone
              raise ArgumentError, "join: only applies to the base (an unconditional headline)" if !join.nil? && !base
              raise ArgumentError, "join: must be a String or a callable ->(base, reason) {}" if !join.nil? && !(join.is_a?(String) || join.respond_to?(:call))

              new(handler:, standalone:, join:, matcher:)
            end
          end
        end
      end
    end
  end
end
