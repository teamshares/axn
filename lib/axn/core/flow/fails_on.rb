# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  module Core
    module Flow
      # `fails_on` reclassifies the listed exception classes from the "exception" bucket
      # into the "failure" bucket: a matching raised exception settles as a failed result
      # (fires on_failure, not on_exception; skips the global on_exception report) WITHOUT
      # being wrapped in Axn::Failure, so the original exception is preserved on
      # `result.exception` and the existing `error` message DSL still resolves its message.
      module FailsOn
        def self.included(base)
          base.class_eval do
            class_attribute :_fails_on_matchers, default: [].freeze

            extend ClassMethods
          end
        end

        module ClassMethods
          # @param exceptions [Class, Array<Class>] one or more Exception classes
          # @param message [String, #call, nil] optional message (positional, like fail!)
          # @param standalone [Boolean, nil] forwarded to the wired `error` — true lets the message
          #   replace a declared base headline instead of attaching under it; only meaningful with a
          #   message/block (there is no wired `error` to configure otherwise)
          # @yield optional block receiving the exception (like error { |e| ... })
          def fails_on(exceptions, message = nil, standalone: nil, &block)
            classes = Array(exceptions)
            if classes.empty? || classes.any? { |c| !(c.is_a?(Class) && c <= Exception) }
              raise ArgumentError, "fails_on requires one or more Exception classes (got #{exceptions.inspect})"
            end

            _reject_unreachable_fails_on!(classes)

            # standalone: only configures the wired `error`, so it's inert without a message/block —
            # raise rather than silently drop it (true and false alike), matching the message DSL.
            raise ArgumentError, "fails_on standalone: has no effect without a message or block" if !standalone.nil? && !(message || block)

            self._fails_on_matchers = (_fails_on_matchers + classes).freeze

            # Wire the message through the existing `error` DSL when provided. Uses an OR proc
            # (not `if: classes`) because `if:` with an array matches via `all?` (AND). standalone:
            # is forwarded verbatim (nil = the DSL's conditional default: an attached reason).
            if message || block
              error(message, if: ->(exception:) { classes.any? { |klass| Axn::Internal::Identity.kind?(exception, klass) } },
                             standalone:, &block)
            end

            true
          end

          # Undispatched ancestry: this decides whether an exception is RECLASSIFIED as a failure — no
          # global report, `on_failure` instead of `on_exception` — so an instance answering it is an
          # instance deciding whether its own bug gets reported. Read from `_settle_exception!`, where a
          # raising `is_a?` would take down the settlement it is classifying.
          def _fails_on?(exception)
            _fails_on_matchers.any? { |klass| Axn::Internal::Identity.kind?(exception, klass) }
          end

          private

          # An exception axn never absorbs into a result (a signal, an `exit`, another library's private
          # control-flow signal — see Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR) is raised straight
          # through `.call` and never reaches failure classification. Declaring `fails_on` on one is
          # therefore inert, and silence would be the worst outcome: the whole point of the declaration is
          # to reclassify, so a caller would reasonably believe they had. Reject it at declaration.
          #
          # Rejects only a class that could NEVER match — one with no swallowable class anywhere in its
          # hierarchy, in either direction. `fails_on Exception` is fine (it still catches every exception
          # axn absorbs); `fails_on Interrupt` is not.
          def _reject_unreachable_fails_on!(classes)
            unreachable = classes.reject { |klass| _fails_on_reachable?(klass) }
            return if unreachable.empty?

            raise ArgumentError,
                  "fails_on cannot reclassify #{unreachable.map { |klass| klass.name || klass.inspect }.join(', ')} — axn never converts " \
                  "#{unreachable.one? ? 'it' : 'them'} into a result (a signal, an `exit`, or a library's own " \
                  "control-flow signal is raised straight through `.call`), so the declaration would have no " \
                  "effect. Remove it, and rescue at the call site if the caller needs to handle it."
          end

          def _fails_on_reachable?(klass)
            return true if klass <= StandardError

            Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR.any? do |swallowable|
              klass <= swallowable || swallowable <= klass
            end
          end
        end
      end
    end
  end
end
