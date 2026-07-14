# frozen_string_literal: true

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

            # standalone: only configures the wired `error`, so it's inert without a message/block —
            # raise rather than silently drop it (true and false alike), matching the message DSL.
            raise ArgumentError, "fails_on standalone: has no effect without a message or block" if !standalone.nil? && !(message || block)

            self._fails_on_matchers = (_fails_on_matchers + classes).freeze

            # Wire the message through the existing `error` DSL when provided. Uses an OR proc
            # (not `if: classes`) because `if:` with an array matches via `all?` (AND). standalone:
            # is forwarded verbatim (nil = the DSL's conditional default: an attached reason).
            error(message, if: ->(exception:) { classes.any? { |klass| exception.is_a?(klass) } }, standalone:, &block) if message || block

            true
          end

          def _fails_on?(exception)
            _fails_on_matchers.any? { |klass| exception.is_a?(klass) }
          end
        end
      end
    end
  end
end
