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

          # Per-adapter provider-name overrides ({adapter => raw_name}), rebuilt fresh on each `tool`
          # call. A class_attribute so a subclass inherits the parent's tool identity until it redeclares
          # `tool`. Frozen default: never mutate in place, always assign a fresh hash.
          class_attribute :_tool_name_overrides, instance_accessor: false, default: {}.freeze

          # Per-adapter opt-out ({adapter}), rebuilt fresh on each `tool` call. Subtracted from the
          # union of directory + declaration grants at membership time. class_attribute so a subclass
          # inherits until it redeclares; frozen default, never mutated in place.
          class_attribute :_tool_except, instance_accessor: false, default: [].freeze
          extend ClassMethods
        end
      end

      module ClassMethods
        # Distinguishes an omitted `except:` keyword from an explicit `except: nil`. A caller passing
        # `except:` at all — even a dynamic value that resolves to nil — is using the narrowing form
        # (directory-grant base); only omitting it entirely leaves the broad `:all` default in play.
        EXCEPT_OMITTED = Object.new.freeze
        private_constant :EXCEPT_OMITTED
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

        # Declares tool membership. Final membership is (directory grant ∪ this declaration) − except.
        #   tool                  -> grant every registered adapter (regardless of directory)
        #   tool :mcp, :ruby_llm  -> add these adapters to the directory grant
        #   tool false            -> opt out of every adapter (a helper Axn living under a tool root)
        #   tool except: :ruby_llm-> directory grant, minus :ruby_llm (pure narrowing; grants nothing itself)
        #   tool name: "…"        -> grant all adapters, with a provider-name override
        #   tool mcp: { title: "…" } -> add :mcp with per-adapter config (sugar over configure(:mcp));
        #     a bag `name:` overrides the provider name for that adapter only
        # Unknown adapter symbols are stored as-is (adapters self-register at load; a hard check here
        # would be load-order-hostile) and simply never match tools_for.
        def tool(*adapters, name: nil, except: EXCEPT_OMITTED, **bags)
          # Per-class guard (a plain ivar on the class object, which subclasses do NOT inherit):
          # a second `tool` on the SAME class would silently overwrite _tool_declaration (last-wins),
          # changing membership at tools_for time instead of failing here. Per axn's fail-at-declaration
          # doctrine, reject the repeat. A subclass declaring its own `tool` is a fresh first call
          # (fresh object, no ivar) and is fine.
          if instance_variable_defined?(:@__axn_tool_declared)
            raise ArgumentError, "`tool` was already declared on #{self}; declare all adapters, `name:`, `except:`, and " \
                                 "per-adapter options in a single call (e.g. `tool :mcp, ruby_llm: { … }, name: \"...\"`)."
          end
          @__axn_tool_declared = true

          except_given = !except.equal?(EXCEPT_OMITTED)

          if adapters.include?(false)
            if adapters.length > 1 || !name.nil? || bags.any? || except_given
              raise ArgumentError, "`tool false` opts out; it can't be combined with adapters, `name:`, `except:`, or per-adapter options"
            end

            self._tool_name_override = nil
            self._tool_name_overrides = {}.freeze
            self._tool_except = [].freeze
            self._tool_declaration = false
            return
          end

          except_list = except_given ? Array(except).uniq : []

          # Adapter identity must be a Symbol everywhere it appears — positional, bag key, or except —
          # so membership stays Symbol-keyed end to end (a `**string_keyed` splat can smuggle a String).
          non_symbols = (adapters + bags.keys + except_list).reject { |a| a.is_a?(Symbol) }
          raise ArgumentError, "tool adapters must be Symbols (e.g. `tool :mcp`); got #{non_symbols.inspect}" if non_symbols.any?

          non_hash = bags.reject { |_adapter, opts| opts.is_a?(Hash) }
          unless non_hash.empty?
            raise ArgumentError,
                  "tool per-adapter options must be Hashes (e.g. `tool mcp: { title: \"...\" }`); got #{non_hash.inspect}"
          end

          # A shared `name:` that sanitizes away entirely (e.g. "!!!" or whitespace-only) would yield a
          # blank tool_name, violating the never-blank contract. Fail at declaration. A nil name is not an error.
          if !name.nil? && _tool_name_sanitize(name).empty?
            raise ArgumentError,
                  "tool name: #{name.inspect} has no provider-safe characters ([a-z0-9_]); " \
                  "provide a name containing at least one such character"
          end

          # Always assign (even when name is nil): `_tool_name_override` is a class_attribute, so a fresh
          # `tool` without `name:` must clear an inherited override rather than let the parent's leak through.
          self._tool_name_override = name
          self._tool_except = except_list.freeze

          # Membership grant from the declaration:
          #   - an explicit list (positional adapters ∪ bag keys) grants exactly those adapters;
          #   - a broad gesture with no list — bare `tool`, or `tool name:` — grants every registered
          #     adapter (:all);
          #   - a bare `except:` (narrowing with no adapters/bags/name) grants nothing itself and relies
          #     on the directory grant (an empty Array — NOT :all, which would re-expose the tool to
          #     every adapter but the excepted one, defeating directory scoping). Its base is the
          #     directory grant whether `except:` is empty, populated, or an explicit nil — passing the
          #     keyword at all selects the narrowing form.
          # `name:` is a broad gesture, so `tool name:, except:` stays :all-minus-except rather than
          # collapsing to directory-only.
          declared = (adapters + bags.keys).uniq
          narrowing_only = declared.empty? && name.nil? && except_given
          self._tool_declaration =
            if declared.any?
              declared
            elsif narrowing_only
              []
            else
              :all
            end

          _apply_tool_bags!(bags)

          nil
        end

        # The provider-facing tool name. With an `adapter`, a per-adapter `tool <adapter>: { name: }`
        # override wins first; then an explicit shared `tool name:`; then derivation from `axn_name`/class
        # name (strip configured prefixes, snake_case, restrict to [a-z0-9_], never blank). Zero-arg
        # `tool_name` skips the per-adapter tier and is unchanged. The `adapter` arg is consumed internally
        # by the registry; users never pass it.
        def tool_name(adapter = nil)
          if adapter && (raw = _tool_name_overrides[adapter])
            sanitized = _tool_name_sanitize(raw)
            return sanitized unless sanitized.empty?
          end

          # Defense-in-depth: the `tool` DSL rejects an override that sanitizes to empty, but an
          # override set through some other path must still never produce a blank name — sanitize and fall through.
          override = _tool_name_override
          if override
            sanitized_override = _tool_name_sanitize(override)
            return sanitized_override unless sanitized_override.empty?
          end

          # `axn_name.presence || name.presence` — NOT `resolved_axn_name` — so a truly nameless class
          # falls back to "tool" below rather than deriving from the "Anonymous Axn" sentinel.
          source = axn_name.presence || name.presence
          return "tool" if source.nil? || source.strip.empty?

          segments = source.split("::")
          kept = _tool_name_strip_leading_prefixes(segments)
          derived = _tool_name_sanitize(kept.map(&:underscore).join("_"))
          return derived unless derived.empty?

          last = _tool_name_sanitize(segments.last.to_s.underscore)
          last.empty? ? "tool" : last
        end

        private

        # A per-adapter bag is sugar over `configure(<adapter>)` for opaque config; the `name` key is
        # the one exception — it is core-owned (feeds tool_name), so it is intercepted here and never
        # written to the config store. Everything else routes through the same NamespaceWriter.
        def _apply_tool_bags!(bags)
          per_adapter_names = {}
          bags.each do |adapter, opts|
            opts = opts.dup
            # `name` is core-owned; accept it whether written with a symbol or string key — the same
            # leniency NamespaceWriter applies to the config keys below — and always delete both forms
            # so it can never leak into the config store. A symbol key wins if the bag carries both.
            sym_name = opts.delete(:name)
            str_name = opts.delete("name")
            adapter_name = sym_name.nil? ? str_name : sym_name
            unless adapter_name.nil?
              if _tool_name_sanitize(adapter_name).empty?
                raise ArgumentError,
                      "tool #{adapter.inspect} name: #{adapter_name.inspect} has no provider-safe characters " \
                      "([a-z0-9_]); provide a name containing at least one such character"
              end
              per_adapter_names[adapter] = adapter_name
            end

            next if opts.empty?

            axn_configure(adapter) do |writer|
              opts.each { |key, value| writer.public_send("#{key}=", value) }
            end
          end
          self._tool_name_overrides = per_adapter_names.freeze
        end

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
