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
        # A concrete tool commonly SUBCLASSES an Axn base (`class MyTool < ApplicationAction`)
        # rather than including Axn directly, so `Axn.included` never re-fires for it and the
        # registry would otherwise omit it. Register every subclass here too. `super` runs FIRST
        # so other libraries' `inherited` hooks (ActiveSupport::DescendantsTracker, Mountable's
        # own, a user base class's) stay intact — `Class#inherited` is a no-op by default, so
        # keeping it in the chain is safe. Registration is idempotent (Registry uses a Set).
        def inherited(subclass)
          super
          Axn::Tools::Registry.register_class(subclass)
        end

        # Declares tool membership.
        #   tool                  -> member of every registered adapter (the common case)
        #   tool :mcp, :ruby_llm  -> explicit per-adapter set
        #   tool false            -> opt out (a helper Axn living under a tool_path)
        #   tool name: "…"        -> membership in all adapters, with a provider-name override
        # Unknown adapter symbols are stored as-is (adapters self-register at load; a hard check
        # here would be load-order-hostile) and simply never match tools_for.
        def tool(*adapters, name: nil)
          if adapters.include?(false)
            raise ArgumentError, "`tool false` opts out; it can't be combined with adapters or `name:`" if adapters.length > 1 || !name.nil?

            self._tool_declaration = false
            return
          end

          non_symbols = adapters.reject { |a| a.is_a?(Symbol) }
          raise ArgumentError, "tool adapters must be Symbols (e.g. `tool :mcp`); got #{non_symbols.inspect}" if non_symbols.any?

          # A provided `name:` that sanitizes away entirely (e.g. "!!!" or whitespace-only) would
          # yield a blank tool_name, violating the never-blank contract. Fail at declaration rather
          # than silently accept an unusable override. A nil name (not provided) is not an error.
          unless name.nil?
            if _tool_name_sanitize(name).empty?
              raise ArgumentError,
                    "tool name: #{name.inspect} has no provider-safe characters ([a-z0-9_]); " \
                    "provide a name containing at least one such character"
            end

            self._tool_name_override = name
          end

          self._tool_declaration = adapters.empty? ? :all : adapters
          nil
        end

        # The provider-facing tool name (distinct from resolved_axn_name, the free-form display
        # name). An explicit `tool name:` override wins; otherwise derive from the class name by
        # stripping the leading run of configured prefixes, snake_casing the rest, and restricting
        # to [a-z0-9_]. Never blank.
        def tool_name
          # Defense-in-depth: the `tool` DSL rejects an override that sanitizes to empty, but an
          # override set through some other path (a direct class_attribute write) must still never
          # produce a blank name — sanitize first and fall through to derivation if nothing survives.
          override = _tool_name_override
          if override
            sanitized_override = _tool_name_sanitize(override)
            return sanitized_override unless sanitized_override.empty?
          end

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
