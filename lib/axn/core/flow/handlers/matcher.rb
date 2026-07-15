# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"

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
            result = matches?(exception:, action:)
            @invert ? !result : result
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("determining if handler applies to exception", action:, exception: e)
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
                klass && exception.is_a?(klass)
              rescue NameError
                action.warn("Ignoring apparently-invalid matcher #{@rule.inspect} -- neither action method nor constant found")
                false
              end
            end
          end

          def apply_string(exception:)
            klass = Object.const_get(@rule.to_s)
            klass && exception.is_a?(klass)
          end

          def apply_exception_class(exception:)
            exception.is_a?(@rule)
          end

          def handle_invalid(action:)
            action.warn("Ignoring apparently-invalid matcher #{@rule.inspect} -- could not find way to apply it")
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
            matches?(exception:, action:)
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("determining if handler applies to exception", action:, exception: e)
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
