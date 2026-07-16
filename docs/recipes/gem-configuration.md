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
Axn::MCP.reset_config!                            # discard assigned values — primarily for test isolation
```

## Setting options

| Option | Effect |
| ------ | ------ |
| `default:` | Value returned until one is assigned. Mutable defaults (e.g. `[]`) are copied per config, so they're safe to assign-then-mutate. |
| `one_of:` | Whitelist of permitted values; assigning anything else raises `ArgumentError`. |
| `validate:` | A callable returning truthy for valid values; anything else raises `ArgumentError`. The callable may instead raise its own `ArgumentError` for a custom message. |
| `callable:` | When `true`, a proc value is resolved (called) at read time — useful for a setting like `enabled` that may be a static boolean or a dynamic check. A callable **default** is re-evaluated on every read, so "unset ⇒ derive from the environment now" is expressible: `setting :sandbox_mode, default: -> { defined?(Rails) ? !Rails.env.production? : true }, callable: true`. |
| `overridable:` | When `true`, individual actions can override the value per-class (see below). |

When migrating an existing config onto `one_of:` or `validate:`, note that the `ArgumentError` raised on an invalid assignment uses the DSL's own wording (e.g. `mode must be one of :a, :b; got :z`) rather than any message your hand-written setter used before — so any tests asserting on the old message text will need updating.

## Per-action overrides

For a setting declared `overridable: true`, individual action classes can override the library default. The override accessors come from a generated module — include it **once**, in the base class your gem's actions already inherit from. Action authors then get the accessors for free and never write the include themselves:

```ruby
module Axn::MCP
  extend Axn::Configurable

  setting :mcp_text_content, default: :structured, one_of: %i[structured message], overridable: true
end

# Once, in your gem's base class:
class Axn::MCP::Tool
  include Axn
  include Axn::MCP.overrides
end

# Action authors just inherit — no extra include:
class MyTool < Axn::MCP::Tool
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

## Declaring validated settings on a class

The same kernel powers Axn's own `Axn::Configuration`. If you have a plain class (rather than a singleton namespace) that needs validated settings-with-defaults on its instances, extend `Axn::Configurable::Settings`:

```ruby
class Configuration
  extend Axn::Configurable::Settings

  setting :log_level, default: :info
  setting :mode, default: :a, one_of: %i[a b]
end
```

This defines instance-level `log_level` / `log_level=` accessors (with the same `default:` / `one_of:` / `validate:` / `callable:` options) while leaving you free to hand-write any other methods the class needs — which is exactly how Axn keeps its side-effecting settings (`env`, `logger`, `on_exception`, the async setters) bespoke while declaring the simple ones via the DSL.
