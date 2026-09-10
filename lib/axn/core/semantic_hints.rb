# frozen_string_literal: true

module Axn
  module Core
    # Advisory-only side-effect / operational profile. Nothing enforces it (a read_only tool can
    # still fire a destructive call, especially `idempotent`) — the _hints suffix keeps that honest.
    # Core owns :read_only/:idempotent/:destructive; adapters extend the vocab via
    # Axn::Extensions.config.register_semantic_hint. Adapters interpret hints (MCP annotations,
    # REST verb, RubyLLM gating).
    module SemanticHints
      def self.included(base)
        base.class_eval do
          class_attribute :_semantic_hints, instance_accessor: false, default: [].freeze
          extend ClassMethods
        end
      end

      module ClassMethods
        def semantic_hints(*hints)
          return _semantic_hints if hints.empty?

          # `semantic_hints [:read_only, :idempotent]` (an Array handed to the splat instead of
          # `semantic_hints :read_only, :idempotent`) used to reach `.to_sym` on the Array itself and
          # raise a bare NoMethodError. Named here instead.
          non_symbolic = hints.reject { |hint| hint.is_a?(Symbol) || hint.is_a?(String) }
          if non_symbolic.any?
            raise ArgumentError,
                  "semantic_hints must be Symbols or Strings, given variadically (e.g. `semantic_hints :read_only`); " \
                  "got #{non_symbolic.inspect}"
          end

          hints = hints.map(&:to_sym)
          vocab = Axn::Extensions.config.registered_semantic_hints
          unknown = hints.reject { |h| vocab.include?(h) }
          raise ArgumentError, "Unknown semantic hint(s): #{unknown.map(&:inspect).join(', ')}. Known: #{vocab.to_a.sort.join(', ')}" if unknown.any?

          self._semantic_hints = hints.freeze
        end
      end
    end
  end
end
