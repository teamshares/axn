# Configuration for Axn-based Gems

This recipe is for **gem authors** building on top of Axn (e.g. `axn-mcp`, `axn-ruby_llm`), not for applications configuring their own Axn instance — for that, see [Configuration](/reference/configuration).

If your gem needs its own settings, you can declare them with the same machinery Axn uses internally rather than hand-rolling a config object, a `configure` yielder, and validation. Extend `Axn::Configurable` on your namespace module and declare each setting:

```ruby
module Axn::MCP
  extend Axn::Configurable

  setting :mcp_text_content, default: :structured, one_of: %i[structured message]
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
| `validate:` | A callable returning truthy for valid values; anything else raises `ArgumentError`. |
| `callable:` | When `true`, a proc value is resolved (called) at read time — useful for a setting like `enabled` that may be a static boolean or a dynamic check. |
| `overridable:` | When `true`, individual actions can override the value per-class (see below). |

## Per-action overrides

For a setting declared `overridable: true`, individual action classes can override the library default. Include the generated overrides module in your action (or, more commonly, in a base class your gem's actions inherit from):

```ruby
module Axn::MCP
  extend Axn::Configurable

  setting :mcp_text_content, default: :structured, one_of: %i[structured message], overridable: true
end

class MyTool
  include Axn
  include Axn::MCP.overrides

  mcp_text_content :message     # class-level override (validated like any assignment)
end

MyTool.resolved_mcp_text_content    # => :message
OtherTool.resolved_mcp_text_content # => :structured (falls back to Axn::MCP.config)
```

Overrides are stored per-class and inherited by subclasses, so a gem can set a default for all of its actions through a shared base class. Resolution walks from the action class up its ancestry to the nearest override, then falls back to the library config value.

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
