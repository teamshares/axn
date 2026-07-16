---
outline: deep
---

# Building Axns from Callables

`Axn::Factory.build` turns a callable (a proc, lambda, or block) into a full Axn class at runtime — the same class you'd get from `include Axn` and a hand-written `call`, but constructed programmatically. It's what backs `Axn::Result.ok`/`Axn::Result.error` and the [mountable](/advanced/mountable) class builder internally, and it's the sanctioned way to relocate a bare callable into a real, nameable Axn.

Reach for it when the action is defined dynamically — a gem exposing a caller-supplied block as a tool, a metaprogrammed family of actions, a one-off built from configuration. For an action you're writing by hand, prefer a plain class (`class MyAction; include Axn; …`): it's clearer and every option below is just the normal class-level DSL.

```ruby
greet = Axn::Factory.build(exposes: [:greeting]) do
  expose greeting: "Hello!"
end

greet.call.greeting # => "Hello!"
```

## Callable vs block

Provide the body as either a positional callable **or** a block — never both (doing so raises `ArgumentError`):

```ruby
Axn::Factory.build(-> { 42 }, expose_return_as: :answer)
Axn::Factory.build(expose_return_as: :answer) { 42 }
```

`expose_return_as:` exposes the callable's return value under the given name (declared `optional:`), so a terse body doesn't need an explicit `expose`.

### Arguments to the callable

The callable may only take **keyword** arguments, and Ruby must be able to introspect them:

- **Required keywords** (`->(user:) { … }`) are automatically declared as `expects :user` — you don't repeat them in `expects:`.
- **Positional arguments** (required, optional, or splat) raise `ArgumentError` — an Axn's interface is entirely keyword-based.
- A **keyword splat** (`**opts`) raises `ArgumentError`.
- **Keywords with defaults** (`->(x: 1) { … }`) raise `ArgumentError`, because Ruby can't introspect the default — declare the field in `expects:` with a `default:` instead.

## Options

Every option below is optional. The builder-specific options shape the class itself; the rest each mirror the class-level DSL method of the same name.

### Builder-specific

| Option | Meaning |
| ------ | ------- |
| `superclass:` | Build the class as a subclass of this class (it gains `include Axn` if it doesn't already). Lets a factory-built Axn inherit configuration or a tool base class. |
| `expose_return_as:` | Expose the callable's return value under this name. |
| `include:` / `extend:` / `prepend:` | Modules (or arrays of modules) to mix into the built class. |

### Mirroring the class DSL

| Option | Mirrors | Notes |
| ------ | ------- | ----- |
| `expects:` / `exposes:` | [`expects`/`exposes`](/reference/class) | A field name, an array of names, or a Hash of `name => options`. |
| `success:` / `error:` | [`success`/`error`](/reference/class) | A message String/callable, or an array of message descriptors. |
| `before:` / `after:` / `around:` | [hooks](/usage/writing) | A callable or array of callables. |
| `on_success:` / `on_failure:` / `on_error:` / `on_exception:` | [callbacks](/reference/class) | A callable or array of callables. |
| `use:` | [strategies](/strategies/) | A strategy name, or `[name, *args, { config }]`; pass an array for several. |
| `async:` | [`async`](/reference/async) | The adapter, or `[adapter, { config }, callable]`. |
| `auto_log:` | `auto_log` | A level (`:info`, `false`), or a Hash of per-outcome levels. |
| `axn_name:` | `axn_name` | The action's canonical display name; also the base for `tool_name`. |
| `description:` | `description` | A human-readable description. |
| `semantic_hints:` | `semantic_hints` | A hint Symbol, or an array of them. |
| `fails_on:` | [`fails_on`](/reference/class) | See [multi-value specs](#multi-value-specs-fails-on-tag-dimension). |
| `tag:` / `dimension:` | `tag` / `dimension` | See [multi-value specs](#multi-value-specs-fails-on-tag-dimension). |

## Multi-value specs: `fails_on`, `tag`, `dimension`

`fails_on`, `tag`, and `dimension` are DSL methods you can call more than once, each call adding another entry. In the factory, the matching option accepts either **a single spec or a list of specs**, and fans out to one DSL call per spec. The rule of thumb: a bare/flat value is one spec; wrap specs in an outer array to register several.

### `fails_on:`

A bare exception class is one matcher. An array is a **list** of specs. Within a spec, a run of exception classes becomes a single matcher over all of them; anything else is `[exceptions, message]` with a trailing Hash forwarded as keywords (e.g. `standalone:`).

```ruby
fails_on: MyError                            # one matcher
fails_on: [TimeoutError, NetworkError]       # two matchers (one class each)
fails_on: [[TimeoutError, NetworkError]]     # one matcher covering both
fails_on: [[MyError, "please retry", { standalone: true }]]
fails_on: [[[NetA, NetB], "network down"]]   # one matcher over both, shared message
```

### `tag:` / `dimension:`

Each spec is `[name, resolver]` (or `[name, resolver, { from: … }]`). A value whose first element is itself an array is a list of specs; otherwise it's a single spec.

```ruby
tag: [:region, "us5"]                        # one tag
tag: [:charged, -> { charged? }, { from: :result }]
tag: [[:region, "us5"], [:tier, "pro"]]      # two tags
dimension: [:plan_tier, "pro"]
```

## Building tools

When a gem exposes a caller-supplied block as a tool (see [Configuration for Axn-based Gems](/recipes/gem-configuration)), the factory is how you relocate that block into a real class. An anonymous factory-built class gets a synthetic `name` (`AnonymousAxn_<id>`) for debugging, so give it an explicit `axn_name:` — `tool_name` derives from it — and a `description:` for the provider:

```ruby
Axn::Factory.build(
  superclass: MyGem::ToolBase,               # [!code focus]
  axn_name: "list_companies",                # [!code focus]
  description: "List companies for the current account", # [!code focus]
  expects: { limit: { type: Integer, optional: true } },
) do
  expose companies: Company.limit(limit || 25)
end
```
