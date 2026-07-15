# frozen_string_literal: true

module Axn
  module Core
    # Tool membership (the `tool` DSL) and the canonical, provider-safe `tool_name`
    # derivation. Every Axn is a potential tool; the registry (Axn::Tools::Registry)
    # decides which classes an adapter actually exposes, reading the storage declared here.
    module Tools
      def self.included(base)
        base.class_eval do
          # instance_accessor: false — class-level DSL, not per-instance state.
          # _tool_declaration: nil (undeclared) | :all | false | Array<Symbol> (explicit adapters).
          class_attribute :_tool_declaration, :_tool_name_override, instance_accessor: false, default: nil
          extend ClassMethods
        end
      end

      module ClassMethods
        # The provider-facing tool name (distinct from resolved_axn_name, the free-form display
        # name). An explicit `tool name:` override wins; otherwise derive from the class name by
        # stripping the leading run of configured prefixes, snake_casing the rest, and restricting
        # to [a-z0-9_]. Never blank.
        def tool_name
          override = _tool_name_override
          return _tool_name_sanitize(override) if override && !override.to_s.strip.empty?

          segments = resolved_axn_name.split("::")
          kept = _tool_name_strip_leading_prefixes(segments)
          derived = _tool_name_sanitize(kept.map(&:underscore).join("_"))
          return derived unless derived.empty?

          last = _tool_name_sanitize(segments.last.to_s.underscore)
          last.empty? ? "tool" : last
        end

        private

        def _tool_name_strip_leading_prefixes(segments)
          prefixes = _tool_name_stripped_prefixes.map(&:to_s)
          index = 0
          index += 1 while index < segments.length && prefixes.include?(segments[index].underscore)
          segments[index..] || []
        end

        def _tool_name_stripped_prefixes
          Axn::Configuration.resolve_override_for(self, :tool_name_stripped_prefixes)
        end

        def _tool_name_sanitize(value)
          value.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
        end
      end
    end
  end
end
