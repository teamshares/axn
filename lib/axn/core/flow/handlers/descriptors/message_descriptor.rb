# frozen_string_literal: true

require "axn/core/flow/handlers/base_descriptor"

module Axn
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            attr_reader :join

            def initialize(matcher:, handler:, standalone: false, join: nil)
              @standalone = standalone
              @join = join
              super(matcher:, handler:)
            end

            def standalone? = @standalone

            # Raise for any unknown option rather than silently dropping it. Surface ALL unknown keys
            # at once so the caller fixes them in one pass rather than one error at a time.
            def self.reject_unsupported_options!(options)
              return if options.empty?

              keys = options.keys.map(&:inspect).join(", ")
              label = options.size == 1 ? "Unknown #{keys} option" : "Unknown options #{keys}"
              raise ArgumentError, "#{label} for error/success message"
            end

            def self.build(handler: nil, if: nil, unless: nil, standalone: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              validate_handler!(handler)
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

            # A message handler must be something the resolver can actually render: a String (used
            # literally), a Symbol (an action method name), or a callable (`instance_exec`'d, like
            # `error`/`fails_on`'s block form). Anything else was accepted silently until now and
            # landed verbatim on `result.error` — `error 42` put the Integer `42` there, violating its
            # documented String contract. `expects ..., user_facing:` already guards this exact
            # grammar (`Contract.validate_user_facing!`); this is the mirror layer that never got it.
            #
            # `nil` is not a handler at all (`_add_message` requires one of message/block before ever
            # reaching here), so it is left alone rather than folded into the grammar it doesn't
            # belong to.
            def self.validate_handler!(handler)
              return if handler.nil?

              case handler
              when ::String, ::Symbol then return
              end
              return if Handlers::Invoker.safely_callable?(handler)

              raise ArgumentError,
                    "a message must be a String, a Symbol, or a callable (got a value of class " \
                    "#{Axn::Internal::Reflection::PropertyNames.renderable_class_name(handler)})"
            end
          end
        end
      end
    end
  end
end
