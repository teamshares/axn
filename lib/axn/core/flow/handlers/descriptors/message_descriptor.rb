# frozen_string_literal: true

require "axn/core/flow/handlers/base_descriptor"

module Axn
  module Core
    module Flow
      module Handlers
        module Descriptors
          # Data structure for message configuration - no behavior, just data
          class MessageDescriptor < BaseDescriptor
            attr_reader :prefix

            def initialize(matcher:, handler:, prefix: nil)
              @prefix = prefix
              super(matcher:, handler:)
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

              Axn::Core::Flow::Handlers::Matcher.new(rules, invert: !!binding.local_variable_get(:unless))
            end

            def self._build_rule_for_from_condition(from_class)
              return nil unless from_class

              from_classes = Array(from_class)
              lambda { |exception:, **|
                return false unless exception.is_a?(Axn::Failure) && exception.source

                source = exception.source
                from_classes.any? do |cls|
                  if cls.is_a?(String)
                    # rubocop:disable Style/ClassEqualityComparison
                    # We're comparing class name strings, not classes themselves
                    source.class.name == cls
                    # rubocop:enable Style/ClassEqualityComparison
                  else
                    source.is_a?(cls)
                  end
                end
              }
            end
          end
        end
      end
    end
  end
end
