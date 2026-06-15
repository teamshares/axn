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
          # @yield optional block receiving the exception (like error { |e| ... })
          def fails_on(exceptions, message = nil, &block)
            classes = Array(exceptions)
            if classes.empty? || classes.any? { |c| !(c.is_a?(Class) && c <= Exception) }
              raise ArgumentError, "fails_on requires one or more Exception classes (got #{exceptions.inspect})"
            end

            self._fails_on_matchers = (_fails_on_matchers + classes).freeze

            # Wire the message through the existing `error` DSL when provided. Uses an OR proc
            # (not `if: classes`) because `if:` with an array matches via `all?` (AND).
            error(message, if: ->(exception:) { classes.any? { |klass| exception.is_a?(klass) } }, &block) if message || block

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
