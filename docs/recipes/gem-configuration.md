# Configuration for Axn-based Gems

This recipe is for **gem authors** building on top of Axn (e.g. `axn-mcp`, `axn-ruby_llm`), not for applications configuring their own Axn instance — for that, see [Configuration](/reference/configuration).

If your gem turns caller-supplied callables into tools, see [Building Axns from Callables](/reference/factory) — it's how you relocate a bare block into a real, nameable Axn class (with an `axn_name:`, `description:`, and the rest of the DSL) rather than poking a class after the fact.

If your gem needs its own settings, you can declare them with the same machinery Axn uses internally rather than hand-rolling a config object, a `configure` yielder, and validation. Extend `Axn::Configurable` on your namespace module and declare each setting:

```ruby
module Axn::MCP
  extend Axn::Configurable

  setting :mcp_text_content, default: :structured, one_of: %i[structured message] # [!code focus]
end
```

That gives you a consistent surface for free:

```ruby
Axn::MCP.config.mcp_text_content                  # => :structured (the default)
Axn::MCP.configure { |c| c.mcp_text_content = :message }
Axn::MCP.config.mcp_text_content                  # => :message
Axn::MCP.config.mcp_text_content?                 # => true (boolean predicate, available for any setting)
Axn::MCP.config.reset!(:mcp_text_content)          # return one setting to its declared default
Axn::MCP.config.reset!                             # return every setting on this config to its declared default
Axn::MCP.reset_config!                             # discard the whole config object — primarily for test isolation
```

`config.reset!` is the supported way back to a setting's declared default — assigning `nil` is a value, not a reset, and would otherwise be the only way to undo an assignment short of reaching into the config's internals. It raises `ArgumentError` for a name that isn't a declared setting. It's distinct from `reset_config!` above: `reset_config!` discards the whole config object (so the next `.config` call rebuilds it from scratch), while `config.reset!` resets individual settings on the config object that's already there. Both flavors of the DSL get `reset!` — on `<Module>.config` for the module-singleton flavor shown here, and directly on a class-flavor config instance (see [Declaring validated settings on a class](#declaring-validated-settings-on-a-class) below).

## Setting options

| Option | Effect |
| ------ | ------ |
| `default:` | Value returned until one is assigned. A Proc default is dynamic: re-derived on every read while the setting is unset, and never cached — so "unset ⇒ derive from the environment now" is expressible, e.g. `setting :sandbox_mode, default: -> { defined?(Rails) ? !Rails.env.production? : true }`. Any other default is copied per config, so a mutable one (e.g. `[]`) is safe to assign-then-mutate. Once a value is assigned, it's returned as-is on every later read — including a Proc, and including `nil` — never invoked and never re-derived. |
| `one_of:` | Whitelist of permitted values; assigning anything else raises `ArgumentError`. |
| `validate:` | A callable checking the assigned value. Returning a truthy non-String value passes. Returning `false` or `nil` raises `ArgumentError` with a generic message. Returning a String also raises `ArgumentError`, but uses that String as the reason — worth it for a setting whose value is an object you supply, where "invalid" alone doesn't hint at the contract. The callable may instead raise its own `ArgumentError` for a fully custom message. This is the opposite polarity of the field-level `validate:` on [`expects`/`exposes`](/reference/class#validation-details), where `nil` means valid and a String is the failure message — a validator lambda written for that DSL (`->(v) { "must be X" unless ok }`, which returns `nil` on success) rejects every value here. |
| `overridable:` | When `true`, individual actions can override the value per-class (see below). |

When migrating an existing config onto `one_of:` or `validate:`, note that the `ArgumentError` raised on an invalid assignment uses the DSL's own wording (e.g. `mode must be one of :a, :b; got :z`) rather than any message your hand-written setter used before — so any tests asserting on the old message text will need updating.

## Per-action overrides

For a setting declared `overridable: true`, individual action classes can override the library default. The override accessors come from a generated module — include it **once**, in the base class your gem's actions already inherit from. Action authors then get the accessors for free and never write the include themselves:

```ruby
module Axn::MCP
  extend Axn::Configurable

  setting :mcp_text_content, default: :structured, one_of: %i[structured message], overridable: true
end

# Once, in a base class your gem's actions inherit from:
class MyGem::ToolBase
  include Axn
  include Axn::MCP.overrides
end

# Action authors just inherit — no extra include:
class MyTool < MyGem::ToolBase
  mcp_text_content :message     # class-level override (validated like any assignment)
end

MyTool.mcp_text_content    # => :message
PlainTool.mcp_text_content # => :structured (falls back to Axn::MCP.config)
```

The explicit include keeps the override accessors opt-in — they appear only on actions that descend from a base that included them, not on every Axn action. Overrides are stored per-class and inherited by subclasses, so setting one on a base class establishes a default for all of its actions. Resolution walks from the action class up its ancestry to the nearest override, then falls back to the library config value.

The no-argument `<name>` reader is the supported way to read an overridable setting — it always returns the effective value (`<name>?` is the same read as a boolean). When a caller needs to distinguish "no override anywhere in the ancestry" from "resolves to the library default", `<name>_override` returns the stored override with no config fallback, or the `Axn::Configurable::UNSET` sentinel when none is set. The internal storage where overrides are kept is private — don't reach into it.

::: warning Load order
`Foo.overrides` only exists once `Foo` has run `extend Axn::Configurable`, and an action captures the override accessors at the moment it runs `include Foo.overrides`. So your namespace's `extend Axn::Configurable` must be evaluated **before** any action that includes its overrides is defined — in practice, declare the module (the `extend` line) above the `require`s that pull in your actions. The order of individual `setting` declarations does not matter: a setting declared after an action includes the overrides is still picked up.
:::

## Declaring per-adapter tool config inline

An action that participates as a tool can declare its per-adapter config right on the `tool` line instead of a detached `configure` block. `tool <adapter>: { … }` is sugar over `configure(<adapter>) { … }` — each key/value lands in the same per-class override store and resolves through the same path, and naming an adapter in the bag implies membership in it:

```ruby
class SearchTool < MyGem::ToolBase
  tool mcp: { present_as: :message, title: "Search" },
       ruby_llm: { halt_after: true }
end
```

is equivalent to:

```ruby
class SearchTool < MyGem::ToolBase
  tool :mcp, :ruby_llm
  configure(:mcp)      { |c| c.present_as = :message; c.title = "Search" }
  configure(:ruby_llm) { |c| c.halt_after = true }
end
```

A class's final adapter membership is a union: whatever a bag key or bare `tool :adapter` names, added to any directory grant the class already has from living under one of that adapter's [`tool_roots`](/reference/configuration#tool-directories-are-declared-per-adapter) — declaring an adapter never subtracts from a directory grant, only adds to it. `tool except: :ruby_llm` is the subtractive counterpart, removing one adapter from membership regardless of how it was granted:

```ruby
class SearchTool < MyGem::ToolBase
  tool except: :ruby_llm   # keep every other adapter (directory- or declaration-granted); drop ruby_llm
end
```

Keys are validated eagerly when the adapter's settings are loaded in this process and stored tolerantly (validated on first read) otherwise, exactly like `configure`. If both spellings write the same key, last-writer-wins into the shared slot.

The one reserved key is `name`: `tool name: "…"` sets the provider-facing [`tool_name`](/reference/class) shared across every adapter, while `name:` inside a bag overrides it for that adapter only (`tool mcp: { name: "search" }`). Everything else in a bag is opaque to core and belongs to the adapter.

## Declaring validated settings on a class

The same kernel powers Axn's own `Axn::Configuration`. If you have a plain class (rather than a singleton namespace) that needs validated settings-with-defaults on its instances, extend `Axn::Configurable::Settings`:

```ruby
class Configuration
  extend Axn::Configurable::Settings

  setting :log_level, default: :info
  setting :mode, default: :a, one_of: %i[a b]
end
```

This defines instance-level `log_level` / `log_level=` accessors (with the same `default:` / `one_of:` / `validate:` options) while leaving you free to hand-write any other methods the class needs — which is exactly how Axn keeps its side-effecting settings (`env`, `logger`, `on_exception`, the async setters) bespoke while declaring the simple ones via the DSL.

An instance also gets `reset!`, same contract as `config.reset!` above: `instance.reset!(:log_level)` returns that one setting to its declared default, `instance.reset!` with no arguments returns every setting declared on the class, and either raises `ArgumentError` for a name that isn't a declared setting. It's the supported alternative to assigning `nil`, which is a value rather than a reset.
