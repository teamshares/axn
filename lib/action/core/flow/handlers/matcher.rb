# frozen_string_literal: true

require "action/core/flow/handlers/invoker"

module Action
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
            Axn::Util.piping_error("determining if handler applies to exception", action:, exception: e)
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
            if exception && Invoker.accepts_exception_keyword?(@rule)
              !!action.instance_exec(exception:, &@rule)
            elsif exception && Invoker.accepts_positional_exception?(@rule)
              !!action.instance_exec(exception, &@rule)
            else
              !!action.instance_exec(&@rule)
            end
          end

          def apply_symbol(action:, exception:)
            if action.respond_to?(@rule)
              method = action.method(@rule)
              if exception && Invoker.accepts_exception_keyword?(method)
                !!action.public_send(@rule, exception:)
              elsif exception && Invoker.accepts_positional_exception?(method)
                !!action.public_send(@rule, exception)
              else
                !!action.public_send(@rule)
              end
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
          # NOTE: invert means it's an unless rather than an if.  This will apply to ALL rules (sufficient for current use case,
          # but flagging if we ever extend this for complex matching)
          def initialize(rules, invert: false)
            @rules = Array(rules).compact
            @invert = invert
          end

          def call(exception:, action:)
            matches?(exception:, action:)
          rescue StandardError => e
            Axn::Util.piping_error("determining if handler applies to exception", action:, exception: e)
          end

          def static? = @rules.empty?

          private

          def matches?(exception:, action:)
            return true if @rules.empty?

            @rules.all? do |rule|
              SingleRuleMatcher.new(rule, invert: @invert).call(exception:, action:)
            end
          end
        end
      end
    end
  end
end
