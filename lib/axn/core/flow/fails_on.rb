# frozen_string_literal: true

require "axn/internal/identity"
require "axn/core/flow/handlers"

module Axn
  module Core
    module Flow
      # `fails_on` reclassifies the listed exception classes from the "exception" bucket
      # into the "failure" bucket: a matching raised exception settles as a failed result
      # (fires on_failure, not on_exception; skips the global on_exception report) WITHOUT
      # being wrapped in Axn::Failure, so the original exception is preserved on
      # `result.exception` and the existing `error` message DSL still resolves its message.
      module FailsOn
        # One `fails_on` declaration: the classes it covers, and an optional `if:`/`unless:` matcher
        # that gates the reclassification itself (nil for an unconditional declaration). Entries are
        # OR'd across declarations -- a conditional entry never narrows an earlier unconditional one.
        Entry = Data.define(:classes, :matcher)
        private_constant :Entry

        def self.included(base)
          base.class_eval do
            class_attribute :_fails_on_entries, instance_accessor: false, default: [].freeze

            extend ClassMethods
          end
        end

        module ClassMethods
          # @param exceptions [Class, Array<Class>] one or more Exception classes
          # @param message [String, #call, nil] optional message (positional, like fail!)
          # @param standalone [Boolean, nil] forwarded to the wired `error` — true lets the message
          #   replace a declared base headline instead of attaching under it; only meaningful with a
          #   message/block (there is no wired `error` to configure otherwise)
          # @param if [Symbol, #call, String, Class, Array, nil] gate(s) that must ALL match (ANDed)
          #   for this declaration to reclassify the exception. Runs at settlement time, against the
          #   action instance and the exception -- same evaluation as `error`/`success`/callbacks
          #   (Handlers::Matcher). Meaningful with or without a message/block: it gates
          #   CLASSIFICATION, a separate concern from what text a message proc renders.
          # @param unless [Symbol, #call, String, Class, Array, nil] gate(s) that must ALL fail to
          #   match for this declaration to reclassify the exception. Combines with `if:` via AND.
          # @yield optional block receiving the exception (like error { |e| ... })
          def fails_on(exceptions, message = nil, standalone: nil, if: nil, unless: nil, &block)
            if_condition = binding.local_variable_get(:if)
            unless_condition = binding.local_variable_get(:unless)

            classes = Array(exceptions)
            if classes.empty? || classes.any? { |c| !(c.is_a?(Class) && c <= Exception) }
              raise ArgumentError, "fails_on requires one or more Exception classes (got #{exceptions.inspect})"
            end

            _reject_unreachable_fails_on!(classes)

            # standalone: only configures the wired `error`, so it's inert without a message/block —
            # raise rather than silently drop it (true and false alike), matching the message DSL.
            raise ArgumentError, "fails_on standalone: has no effect without a message or block" if !standalone.nil? && !(message || block)

            _validate_fails_on_conditions!(if_condition, unless_condition)

            # `classes.dup.freeze`: `Array(exceptions)` returns the CALLER'S array unchanged when one was
            # passed, so storing it bare would alias a declaration to an array the caller still owns.
            entry_matcher = if_condition.nil? && unless_condition.nil? ? nil : Handlers::Matcher.build(if: if_condition, unless: unless_condition)
            entry = Entry.new(classes: classes.dup.freeze, matcher: entry_matcher)
            self._fails_on_entries = (_fails_on_entries + [entry]).freeze

            # Wire the message through the existing `error` DSL when provided, gated so a message
            # never surfaces for an exception this declaration didn't actually reclassify -- gating
            # classification without also gating the message would let the failure-shaped text render
            # on a call that still pages. standalone: is forwarded verbatim (nil = the DSL's
            # conditional default: an attached reason).
            #
            # The gate reads `_fails_on?`'s CACHED verdict (`FailsOnVerdicts`) rather than
            # re-invoking `if_condition`/`unless_condition` itself: both run synchronously within one
            # `_settle_exception!` (classification, then message resolution via presentation
            # stamping), so a condition that isn't perfectly pure -- a counter, a clock, anything
            # stateful -- would otherwise risk classifying one way and presenting the other. Reusing
            # the verdict makes that impossible: the condition runs at most once per exception,
            # period, whether or not a message is declared.
            if message || block
              message_gate = lambda { |exception:|
                # `entry.classes`, NOT the bare `classes` local -- that's `Array(exceptions)`, the
                # CALLER'S own array when one was passed (see the aliasing note above `entry_matcher`).
                # Closing over it here would let classification (which reads the frozen `entry.classes`)
                # and this gate disagree the moment a caller mutates the array they originally handed
                # `fails_on` after the fact.
                next false unless entry.classes.any? { |klass| Axn::Internal::Identity.kind?(exception, klass) }
                next true if entry_matcher.nil?

                cached = Axn::Internal::FailsOnVerdicts.fetch(exception, entry)
                next cached unless cached.nil?

                # Defensive only: `_fails_on?` always runs first in the settle path this ships with,
                # so the cache should already be populated by the time any message resolves. `self`
                # here is the action (Invoker instance_execs this proc), same receiver `_fails_on?`
                # itself would be called with.
                entry_matcher.call(exception:, action: self)
              }
              error(message, if: message_gate, standalone:, &block)
            end

            true
          end

          # Full verdict: does ANY declared entry reclassify this exception, evaluating each entry's
          # `if:`/`unless:` gate (if any) against `action`. Runs user code (via Handlers::Matcher), so
          # it is consulted ONLY from `_settle_exception!`, which owns the error-handling policy for
          # everything it dispatches (Handlers::Invoker's best_effort: a raising gate warns and reads
          # as no match, never replacing the settlement it is deciding).
          #
          # `action:` is required, not defaulted -- a call site that forgets it raises loudly instead
          # of silently treating every conditional entry as a non-match.
          #
          # Records each conditional entry's verdict (`FailsOnVerdicts`) as it's computed, so a
          # declared message's own gate (built in `fails_on` above) can reuse the SAME answer instead
          # of asking the condition again -- the condition runs at most once per exception either way.
          def _fails_on?(exception, action:)
            _fails_on_entries.any? do |entry|
              next false unless entry.classes.any? { |klass| Axn::Internal::Identity.kind?(exception, klass) }
              next true if entry.matcher.nil?

              verdict = entry.matcher.call(exception:, action:)
              Axn::Internal::FailsOnVerdicts.record!(exception, entry, verdict)
              verdict
            end
          end

          # Static entries only -- undispatched (Internal::Identity.kind?), runs no user code. This is
          # what `Result#outcome` reads: a conditional entry's verdict has exactly one author (the
          # settle path, via `_fails_on?` above) and exactly one evaluation, recorded onto the context
          # before anything else can observe it -- a `Result`, read from `inspect`/logging/serialization
          # on every later call, may neither re-derive that verdict nor run user code to get one.
          def _unconditionally_fails_on?(exception)
            _fails_on_entries.any? do |entry|
              entry.matcher.nil? && entry.classes.any? { |klass| Axn::Internal::Identity.kind?(exception, klass) }
            end
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
                  "fails_on cannot reclassify #{unreachable.map { |klass| Axn::Internal::Rendering.module_name(klass) }.join(', ')} — axn never converts " \
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

          # Fail at declaration rather than let an unusable gate warn-and-silently-never-match at run
          # time (or, worse, silently ALWAYS match -- see the boolean case below).
          def _validate_fails_on_conditions!(if_condition, unless_condition)
            { if: if_condition, unless: unless_condition }.each do |key, condition|
              next if condition.nil?

              rules = Array(condition).compact
              raise ArgumentError, "fails_on #{key}: cannot be an empty condition -- omit the option instead" if rules.empty?

              rules.each { |rule| _validate_fails_on_rule!(key, rule) }
            end
          end

          def _validate_fails_on_rule!(key, rule)
            return if Handlers::SingleRuleMatcher.applicable?(rule)

            if rule.equal?(true) || rule.equal?(false)
              raise ArgumentError,
                    "fails_on #{key}: gates classification at RUN time and takes a Symbol, a callable, or an " \
                    "Exception class -- not a boolean (`false` would mean always reclassify, `true` would mean " \
                    "never). For a decision you can make when the class loads, guard the declaration itself: " \
                    "`fails_on X if cond`."
            end

            raise ArgumentError,
                  "fails_on #{key}: cannot apply #{rule.inspect} -- expected a Symbol, a callable, a String " \
                  "naming a constant, or an Exception class"
          end
        end
      end
    end
  end
end
