# Running Without Rails

Axn runs standalone — it depends on ActiveSupport and ActiveModel, not on Rails. Everything in the DSL works in a plain Ruby process, a Sinatra app, a Sidekiq-only worker, or a CLI.

What Rails gives you is **wiring**: an autoload path, a boot sequence to hook, a transaction to defer callbacks onto, and `Rails.root` to resolve paths against. Without it, those are seams you own yourself. This page is the list of them — nothing here is a limitation to work around, just a hand-off.

## The seams at a glance

| Seam | With Rails | Without Rails |
| --- | --- | --- |
| [Tool-contract validation at setup](#tool-contract-validation) | Automatic (`after_initialize`, and again on each reload) | Call `Axn.validate_tool_contracts!` yourself |
| [Loading your action files](#loading-your-action-files) | `app/actions` is on the autoload path | `require` your action files yourself |
| [Loading tool directories](#loading-tool-directories) | Zeitwerk loads each directory as one unit | One `require` per file, each isolated |
| [Resolving tool roots](#resolving-tool-roots) | Relative entries resolve under `Rails.root/app` | Supply absolute paths |
| [`on_success` timing](#on-success-timing) | Deferred to after the outermost transaction commits | Runs inline |
| [`use :transaction`](#use-transaction) | Wraps the call in a transaction | Raises `NotImplementedError` |
| [`model:` fields](#model-fields) | ActiveRecord lookup | Any class answering the finder |
| Generators | `rails g axn …` | Not available — write the file |
| [Profile output path](#profile-output-path) | `Rails.root/tmp/profiles` | `tmp/profiles`, relative to the working directory |

## Tool-contract validation

Two of axn's contract rules — a name with no UTF-8 rendering, and two names that collapse onto one JSON property — are judged on the schema your contract projects, so they raise when that projection is first built rather than when the class is defined. For a [tool axn](/recipes/authoring-tool-adapters) the projection is what an adapter hands a model, so you want the error at setup, not on someone's tool call.

Under Rails the engine arranges that for you. Without Rails there is no boot to hook, so call it yourself once your action files are loaded:

```ruby
require "axn"
Dir[File.expand_path("app/actions/**/*.rb", __dir__)].sort.each { |file| require file }

Axn.validate_tool_contracts! # [!code focus]
```

It projects every registered tool once and raises on the first invalid contract, naming the offending class. Nothing changes if you skip it — the same errors still raise the first time anything projects that contract — you just find out later.

::: warning What it covers
The guarantee is exactly as wide as enumeration, and no wider:

* **At least one tool adapter must be registered.** With none there are no tool roots and no membership to test, so the call is a no-op.
* **A tool inside a configured tool root is loaded and validated**, whether it earned membership from the directory or from a `tool` declaration.
* **A `tool`-DSL axn outside every configured root is only covered once something has loaded it.** If you require your action files up front (as above) that is always true. If you load lazily, it falls back to validating on first projection.
* **A directory whose load aborted takes its siblings with it.** Under Rails, Zeitwerk loads a directory as one unit, so one raising file skips the rest of that directory — warn-logged, and unvalidated. Outside Rails each file is required independently, so this one does not apply to you.

Anything not reached still raises on first projection. Nothing becomes silently valid.
:::

## Loading your action files

Under Rails the engine pushes `app/actions` onto the autoloader, so referencing `MyAction` loads it. Standalone, nothing is autoloaded for you: `require` your action files, or point your own Zeitwerk loader at them.

This matters more than it looks, because several things in axn enumerate *loaded* classes — tool membership among them. A class that has not been required does not exist yet.

## Loading tool directories

Both paths are isolated against a broken file, but the granularity differs:

* **Rails**: Zeitwerk has no public API to load one managed file in isolation, so a directory loads as a unit. One raising file aborts the rest of *that* directory (warn-logged); other tool roots load independently.
* **Standalone**: each `require` is rescued on its own, so one bad file is warn-logged and skipped without affecting its siblings.

Standalone is the finer-grained of the two.

## Resolving tool roots

A relative `tool_roots` entry is resolved under `Rails.root/app`, so `"actions/tools"` means `<root>/app/actions/tools`. Without `Rails.root` there is nothing to resolve against — a relative entry is expanded against the working directory, which is rarely what you want. **Supply absolute paths:**

```ruby
Axn::MCP.config.tool_roots = [File.expand_path("app/actions/tools", __dir__)] # [!code focus]
```

See [Authoring a Tool-Adapter Gem](/recipes/authoring-tool-adapters) for how an adapter declares roots in the first place.

## `on_success` timing

With ActiveRecord 7.2+ loaded, `on_success` callbacks are deferred to `ActiveRecord.after_all_transactions_commit`, so a callback never fires for work that later rolls back. Without ActiveRecord — or on an older version — there is no commit to hook, and callbacks **dispatch inline**.

If your side effects must not fire for rolled-back work, that ordering is yours to arrange.

## `use :transaction`

Requires ActiveRecord and raises `NotImplementedError` at class definition without it. Wrap your own unit of work instead.

## `model:` fields

`model:` resolves a record from a `<field>_id` by calling a finder on the declared class — `:find` by default, or whatever you pass as `finder:` (a method name or a `Method` object). Nothing about that is ActiveRecord-specific: **any class that answers the finder works**, including a plain PORO.

```ruby
class Widget
  def self.find(id) = REGISTRY.fetch(id)
end

expects :widget, model: Widget # [!code focus]
```

Axn's own non-Rails test suite uses POROs with a finder for exactly this. See [validation details](/reference/class#validation-details) for the full `model:` option surface.

## Profile output path

The [Vernier profiling strategy](/advanced/profiling) writes to `Rails.root/tmp/profiles` under Rails, and to `tmp/profiles` relative to the working directory otherwise.

## Related

* [`ambient_context`](/reference/class#ambient-context-on-ambient-context) — the Rails path reads registered `ActiveSupport::CurrentAttributes`; supply your own provider otherwise.
* [Mountable actions](/advanced/mountable) — no Rails involvement either way.
* [Async execution](/reference/async) — adapter-driven, and independent of Rails; `async :disabled` raises `NotImplementedError` on `call_async`.
