# frozen_string_literal: true

module Axn
  module Tools
    # Mixed into an adapter's config module (which already `extend Axn::Configurable`) to declare
    # a validated `tool_roots` directory list. Each adapter names the directories it consumes; the
    # registry reads `<adapter>.config.tool_roots` to compute directory-based membership. Validation
    # reuses core's single broad-path guard so no adapter can widen a root to `app/`, `.`, `actions`,
    # or a `..` traversal that would bulk-expose every business action.
    module AdapterRoots
      # The single written copy of the broad-root guard, referenced by both `self.extended`'s
      # `validate:` and `tool_roots_default` below — so an adapter that widens the shipped default
      # (`tool_roots_default %w[agent_tools]`) still runs the exact validation an app's own assignment
      # would, rather than a second hand-copied lambda that could drift from this one.
      VALIDATE = ->(value) { AdapterRoots.validate!(value) }
      private_constant :VALIDATE

      # Bound so `tool_roots_default` detaches an entry through Ruby's OWN unary-minus dedup/freeze
      # rather than dispatching `-entry`, which a `String` subclass in the array could override to
      # return `self` (or any other still-mutable, still caller-owned string) — passing
      # `entry.is_a?(String)` in `validate!` costs nothing, since `is_a?` admits every subclass. A
      # bound `UnboundMethod#bind_call` runs the native implementation directly, with no method
      # lookup on the receiver's class, so an overridden `-@` (or a hostile `dup`/`freeze` it might
      # lean on) is never consulted — the same "ask ownership via a bound reader, never a caller's
      # own dispatch" convention AGENTS.md's error-reporting seam already follows.
      NATIVE_STRING_MINUS = ::String.instance_method(:-@)
      private_constant :NATIVE_STRING_MINUS

      def self.extended(base)
        base.setting :tool_roots, default: [], validate: VALIDATE
      end

      # Re-declares `tool_roots` with a non-empty default, for an adapter that wants its own
      # `agent_tools`-style directory convention without hand-copying the validate lambda (the
      # duplication this method exists to remove — every adapter needed it purely to change core's
      # conservative `[]` default). Validates the default EAGERLY, at the call site, so a broad
      # default (`tool_roots_default %w[app]`) fails at gem load — same "fail at declaration, not
      # runtime" discipline as an app's own assignment gets, rather than surfacing only the first time
      # the registry reads `config.tool_roots`.
      #
      # Re-declares via the public `setting` (Axn::Configurable's `setting` replaces a same-named
      # entry in the module's own settings bag), so an app's later `config.tool_roots = [...]` still
      # wins, and `config.reset!(:tool_roots)` returns to THIS default rather than core's `[]`.
      #
      # An INSTANCE method, deliberately, not `self.tool_roots_default` — `extend Axn::Tools::AdapterRoots`
      # installs a module's instance methods as singleton methods of the extending adapter module (the
      # same mechanism that gives it `validate!`'s sibling `self.extended` hook, which Ruby calls
      # automatically and which is never itself extended onto anything). `self` here is the adapter
      # module doing the extending, so `setting` below resolves to ITS OWN `Axn::Configurable#setting`.
      # Stores a DETACHED, frozen copy — never the caller's own array — so a reference the caller
      # still holds cannot retroactively widen an already-validated default. `Setting#default` is
      # stored as-is with no copy of its own; without this, `roots = %w[agent_tools];
      # tool_roots_default(roots); roots << "actions"` would leave `"actions"` sitting in the
      # default having never been validated (validate! ran once, before the mutation, against the
      # OLD array), and `roots.first.replace("actions")` would corrupt the already-declared default
      # in place even later, since `Config#dup_default`'s `default.dup` only copies the array
      # shell — the element STRINGS inside stay shared. Native `String#-@` (unary minus, bound via
      # `NATIVE_STRING_MINUS` below rather than dispatched as `-entry` — see that constant) returns a
      # frozen, deduplicated copy per element, so no string in the stored default is the caller's own
      # object; freezing the array closes the append case. A frozen container is safe to store
      # directly: `dup_default`'s `default.dup` still hands back a fresh, unfrozen Array the FIRST
      # time `config.tool_roots` is read after declaration (`Array#dup` never carries over frozen
      # state), and that dup — not the frozen `detached` array itself — is what stays cached for
      # every read after that, so callers keep seeing an ordinary mutable Array. Only the STORED
      # default is armored against the caller's own reference.
      #
      # Also clears any already-cached value (`config.reset!(:tool_roots)`), not only replacing the
      # `Setting` struct. `Config#_read` caches a default into `@values` on FIRST read
      # (`setting.dup_default`) and every read after that returns the SAME cached object — so if
      # anything in the same class body reads `config.tool_roots` before this method runs, that stale
      # `[]` sits cached and keeps answering even after the Setting is replaced, since replacing the
      # Setting alone never touches `@values`. `reset!` deletes the cache entry so the next read
      # recomputes from the (now freshly-declared) Setting via the ordinary `dup_default` path —
      # reusing the existing reset machinery rather than re-deriving its dup/freeze handling here.
      # This cannot clobber a genuinely later app-level override: an app can only reach `configure {
      # |c| c.tool_roots = ... }` once the whole adapter module has finished loading, strictly AFTER
      # this method (called from within that same load) has already run.
      def tool_roots_default(value)
        AdapterRoots.validate!(value)
        detached = value.map { |entry| NATIVE_STRING_MINUS.bind_call(entry) }.freeze
        setting :tool_roots, default: detached, validate: VALIDATE
        config.reset!(:tool_roots)
      end

      # Returns true when valid; raises ArgumentError with a specific message otherwise. Raising from
      # a `validate:` lambda propagates through Setting#validate! (Axn::Configurable), so a bad root
      # fails at assignment rather than with the generic "got invalid value".
      def self.validate!(value)
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
          raise ArgumentError, "tool_roots must be an Array of Strings; got #{value.inspect}"
        end

        value.each do |entry|
          next unless Axn::Configuration.broad_tool_root?(entry)

          raise ArgumentError,
                "tool_roots entry #{entry.inspect} is too broad: it resolves to the project root, escapes " \
                "via `..`, or ends in a broad directory (`actions`/`app`) that would auto-expose every " \
                "business action. Use a dedicated narrow subdir such as `agent_tools` or `actions/tools`."
        end

        true
      end
    end
  end
end
