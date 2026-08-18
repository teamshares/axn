# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"
require "axn/internal/identity"

module Axn
  module Core
    module Flow
      module Handlers
        class SingleRuleMatcher
          def initialize(rule, invert: false)
            @rule = rule
            @invert = invert
          end

          def call(exception:, action:)
            # A matcher's error policy is set ONE layer down, by Handlers::Invoker, which warns and
            # yields nil (so the rule reads as "no match") for anything axn absorbs. Deliberately NOT
            # `standard_errors_only:` on top of that: a second, stricter layer here would make a matcher
            # raising SystemStackError behave differently from one raising ArgumentError, and worse —
            # since on_success/error matchers are evaluated inside the executor's boundary, letting one
            # through would settle a SUCCESSFUL action as an exception carrying the matcher's own bug.
            # A broken matcher is loud in the log and inert in its effect; it never rewrites the outcome.
            Axn::Extensions.best_effort("determining if handler applies to exception", action:) do
              result = matches?(exception:, action:)
              @invert ? !result : result
            end
          end

          private

          def matches?(exception:, action:)
            return apply_callable(action:, exception:) if callable?
            return apply_symbol(action:, exception:) if symbol?
            return apply_string(exception:) if string?
            return apply_exception_class(exception:) if exception_class?

            handle_invalid(action:)
          end

          def callable? = @rule.respond_to?(:call)
          def symbol? = @rule.is_a?(Symbol)
          def string? = @rule.is_a?(String)
          def exception_class? = @rule.is_a?(Class) && @rule <= Exception

          def apply_callable(action:, exception:)
            !!Invoker.call(action:, handler: @rule, exception:, operation: "determining if handler applies to exception")
          end

          def apply_symbol(action:, exception:)
            if action.respond_to?(@rule)
              !!Invoker.call(action:, handler: @rule, exception:, operation: "determining if handler applies to exception")
            else
              begin
                klass = Object.const_get(@rule.to_s)
                klass && Axn::Internal::Identity.kind?(exception, klass)
              rescue NameError
                Axn::Internal::ActionState.log(action,
                                               "Ignoring apparently-invalid matcher #{@rule.inspect} -- neither action method nor constant found",
                                               level: :warn)
                false
              end
            end
          end

          def apply_string(exception:)
            klass = Object.const_get(@rule.to_s)
            klass && Axn::Internal::Identity.kind?(exception, klass)
          end

          # Undispatched ancestry, here and in the Symbol/String forms above: which declared `error`/
          # `success` handler matches decides the message a caller sees and whether a reason attaches, and
          # matching runs while the failure is being settled. An exception answering for itself picks its
          # own handler; one that raises replaces the settlement with its own exception.
          def apply_exception_class(exception:)
            Axn::Internal::Identity.kind?(exception, @rule)
          end

          def handle_invalid(action:)
            Axn::Internal::ActionState.log(action,
                                           "Ignoring apparently-invalid matcher #{@rule.inspect} -- could not find way to apply it",
                                           level: :warn)
            false
          end
        end

        class Matcher
          # if: and unless: may be combined (ANDed): every if: rule must match AND every unless:
          # rule must not — the same combination rule as steps and field declarations. Multi-rule
          # arrays keep their existing semantics (if: [A, B] requires all; unless: [A, B] requires
          # none).
          def initialize(if_rules: [], unless_rules: [])
            @if_rules = Array(if_rules).compact
            @unless_rules = Array(unless_rules).compact
          end

          def call(exception:, action:)
            # See SingleRuleMatcher#call: matcher error policy is Invoker's, single-layered.
            Axn::Extensions.best_effort("determining if handler applies to exception", action:) do
              matches?(exception:, action:)
            end
          end

          def static? = @if_rules.empty? && @unless_rules.empty?

          # Class method to build matcher from kwargs
          def self.build(if: nil, unless: nil)
            if_condition = binding.local_variable_get(:if)
            unless_condition = binding.local_variable_get(:unless)

            # A bare falsey condition value (e.g. a forwarded feature flag that's currently `false`)
            # means "no condition" -- matching both the pre-existing `||`-based behavior and the
            # field-declaration gates' measured ActiveModel semantics. A falsey element *inside* an
            # array (e.g. `if: [false, :other]`) is left alone and still hits the invalid-matcher path.
            new(
              if_rules: if_condition ? Array(if_condition).compact : [],
              unless_rules: unless_condition ? Array(unless_condition).compact : [],
            )
          end

          private

          def matches?(exception:, action:)
            @if_rules.all? { |rule| SingleRuleMatcher.new(rule).call(exception:, action:) } &&
              @unless_rules.all? { |rule| SingleRuleMatcher.new(rule, invert: true).call(exception:, action:) }
          end
        end
      end
    end
  end
end
