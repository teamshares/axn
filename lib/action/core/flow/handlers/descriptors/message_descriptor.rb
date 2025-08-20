# frozen_string_literal: true

require "action/core/flow/handlers/base_descriptor"

module Action
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            attr_reader :prefix

            def initialize(matcher:, handler:, prefix: nil)
              super(matcher:, handler:)
              @prefix = prefix
            end

            def self.build(handler: nil, if: nil, unless: nil, prefix: nil, from: nil, **)
              new(
                handler:,
                prefix:,
                matcher: _build_matcher(if:, unless:, from:),
              )
            end

            def self._build_matcher(if:, unless:, from:)
              rules = [
                binding.local_variable_get(:if),
                binding.local_variable_get(:unless),
                _build_rule_for_from_condition(from),
              ].compact

              Action::Core::Flow::Handlers::Matcher.new(rules, invert: !!binding.local_variable_get(:unless))
            end

            def self._build_rule_for_from_condition(from_class)
              return nil unless from_class

              if from_class.is_a?(String)
                lambda { |exception:, **|
                  exception.is_a?(Action::Failure) && exception.source&.class&.name == from_class
                }
              else
                ->(exception:, **) { exception.is_a?(Action::Failure) && exception.source.is_a?(from_class) }
              end
            end
          end
        end
      end
    end
  end
end
