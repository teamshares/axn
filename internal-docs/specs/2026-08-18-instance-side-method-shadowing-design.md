# Instance-side method shadowing (PRO-3149)

Linear: https://linear.app/teamshares/issue/PRO-3149/axn-instance-side-methodshadowing

## Problem

`Axn::Core::MethodShadowing` makes `include Axn` **defer** to a class-method name a superclass already owns, on the grounds that an adapter base like `Axn::MCP::Tool < ::MCP::Tool` gives `description`/`input_schema`/`output_schema` transport meaning axn must not clobber (PRO-2875). On the instance side axn does the opposite, silently: Ruby places a module included in the subclass above the superclass in the method-resolution order, so `Axn::Core::Logging::InstanceMethods#log` outranks `ApplicationService#log` and the user's own method becomes unreachable with no warning. Relocating the helpers into modules (PRO-3062 §3) is what makes deferral *safe* — internals bind through `Axn::Internal::ActionState` rather than dispatching these names — but it does not make deferral *happen*.

## What the probe found

Every line below was run against this branch, not reasoned.

Two names in this family fail silently and catastrophically today, and neither is a logging helper:

```ruby
class ServiceBase
  def initialize(user:) = @user = user
  def call = do_the_work
end

Class.new(ServiceBase) { include Axn }.call
#  => ok?=true  outcome=success  error=nil
#  call resolves to: Axn::Core::DefaultCall   # ServiceBase#call NEVER RAN
```

That is PRO-3062's worst finding — "the action reports **success** for code that never executed" — reached through inheritance instead of through `expects :call`. `Core::DefaultCall#call` returns early when no exposures are declared, so nothing raises and nothing logs. `initialize` is the same shape: `Axn::Core#initialize(**)` wins, `ServiceBase#initialize` never runs, `@user` is never set, and the action reports success.

The rest of the surface behaves as the ticket describes. With `ApplicationService#log` and `ApplicationService#fail!` in the hierarchy, `log("charging")` reaches axn's logger and loses the parent's request-id tagging, while `fail!("declined")` correctly settles as `outcome=failure, error="declined"` — axn's version winning is *wrong* for the first and *right* for the second, which is why the deferral question cannot be answered per-name by hazard.

Deferral cannot be a non-definition. The sugar modules are shared across every action class, so axn cannot decline per class. A copy of the ancestor's `UnboundMethod` into a module is a `TypeError` (`bind argument must be a subclass of ServiceBase`), but a per-class module included *last* — above axn's, since the most recently included module sits closest to the class — whose method `bind_call`s the ancestor's implementation resolves correctly, and a user's own `def log ... super` in the class body reaches the parent through it. The reverse direction is cheaper still: `define_method(:fail!, Axn::Core.instance_method(:fail!))` is a legal module-to-module copy, and `remove_method` on the shim restores the canonical owner outright (`fail! owner=Axn::Core`, `outcome=failure`).

The `Object` boundary the ticket proposes already exists in the codebase. `Internal::NameOwnership.owner_within(klass, name)` walks `module_ancestors(klass).take_while { _1 != ::Object }`, and its comment already carries the `Kernel#warn` justification. Asked at the top of `Axn.included`, it is clean: a plain class yields `nil` for every name in the surface — `initialize` included, because `BasicObject` sits past `Object` — while a class under `ServiceBase` names `ServiceBase` for exactly the names it declares.

`NameOwnership.conflict_for` already answers the guard question the DSL needs, with no new list: `:call`, `:_run`, `:initialize` return `:unsurrenderable`; `:ambient_context` returns `Axn::Core::AmbientContext`; `:class`/`:hash` return `Kernel`; all 17 sugar names return `nil`. It cannot, however, split the 17 into "control-flow" and "cosmetic" — that distinction is not visible to ownership and would be a hand-kept list, which is why this design does not make it.

Blast radius today is zero. Across os-app, buyout-app, invoice-app, data_shifter, slack_sender, axn-mcp and teamshares-rails, all 2364 `include Axn` sites are on classes with no superclass. The reachable paths are `class Foo < Base; include Axn` and `Axn::Factory`'s documented `superclass:` kwarg.

## Design

### 1. One walk, two receivers

`Axn::Core::MethodShadowing` gains the instance-side check beside the class-side one, sharing a single private walk, because the acceptance criterion is that a future reader meets one rule with one difference rather than two similar checks to reconcile.

The walk is what `externally_defined?` does today: enumerate ancestors, skip anything axn core owns — `Axn::Core` itself as well as its namespace, since `Axn::Core` declares `fail!`/`done!`/`forward!`/`_run`/`initialize` in its own table — and ask `NativeMethods.declares_own_instance_method?`. Three parameters differ:

| | class side (PRO-2875) | instance side (this ticket) |
| -- | -- | -- |
| ancestry | `base.singleton_class.ancestors` | `base.ancestors` |
| truncation | none | `take_while { _1 != ::Object }` |
| `base` itself | included (an explicit `def self.x` defers) | **excluded** (a `def x` in the class body is the user's own, and wins on its own) |

The truncation is the whole difference in kind, and it exists for one reason: `Kernel` owns `warn`, `inspect`, `hash`, `then` and `tap`, and `::Object` stands in front of it in every class's ancestry, so truncating there is what excludes them. An untruncated walk would make axn permanently decline to define `warn` and silently redirect every `warn("msg")` inside an action to stderr. Everything before `Object` is the user's own hierarchy; everything from `Object` outward is Ruby's, and axn takes it.

Skipping only axn core's own modules — not the whole `Axn::` namespace — is carried over unchanged, and it means the same thing here as on the class side: an instance method a base class picks up from a satellite adapter module like `Axn::MCP::*` counts as external, and axn defers to it. That is the case the class-side rule was written for, applied to the other receiver.

Excluding `base` itself is what keeps PRO-3062's wrap idiom intact. `def log(...) = super` written either side of `include Axn` still resolves to the class's own method with `super` reaching axn's, because the class is never a deferral target for itself.

### 2. The surface is derived, not listed

The deferrable surface is the **public own instance methods of `NameOwnership::SURRENDERABLE_OWNERS`, minus `internal_name?`** — 17 names today:

- `Axn::Core`: `fail!`, `done!`, `forward!`
- `Axn::Core::Contract::InstanceMethods`: `result`, `inputs`, `expose`, `default_error`, `default_success`, `execution_context`, `set_execution_context`, `clear_execution_context`
- `Axn::Core::Logging::InstanceMethods`: `log`, `debug`, `info`, `warn`, `error`, `fatal`

Deriving it from `SURRENDERABLE_OWNERS` rather than from the ticket's list is what takes it off the treadmill, and it settles the one discrepancy: the ticket lists 18 names, and the extra one is `ambient_context`, which `SURRENDERABLE_OWNERS` deliberately omits because it is a sentinel rather than a convenience (the subfield resolver compares a route's root against `AmbientContext::PARENT`). A name axn will not let a declaration take is not a name axn will hand to a superclass either; the two questions get one answer.

Private methods are out. `internal_context`, `inputs_for_logging` and `_build_context_facade` are not a surface a user calls, and deferring one would hand axn's internals to a foreign implementation.

### 3. One derived three-way rule

For each name, with `definer` = the walk from §1:

| `definer` | name is | outcome |
| -- | -- | -- |
| present | in the §2 surface | **defer** — install the shim, warn once per definer |
| present | `UNSURRENDERABLE` (`call`, `_run`, `initialize`) | **raise**, naming the owner |
| absent | — | axn defines, exactly as today |

`conflict_for` is the single predicate behind both non-trivial rows and behind §5's guard, so no list of names appears anywhere.

The two rows fire at different times, and the difference is forced rather than chosen:

**Deferral fires inside `Axn.included`, before `include Core`.** The chain is clean there, so the walk needs no special-casing, and the shim installs after the rest of the includes (including `Axn.config.additional_includes`) so it sits above them.

**The unsurrenderable raise fires at the execution entry, `Core::ClassMethods#call`, memoized per class.** At include time the answer is not yet knowable: `Axn::Factory._build_axn_class` legitimately builds `Class.new(superclass)`, includes Axn, and *then* defines its own `call` on the class — a class-owned `call` that outranks both the parent's and `DefaultCall`'s. Raising at include time would reject that as a collision it is not. The check is therefore two questions rather than one — a non-axn ancestor declares the name, AND axn's own definition is what a dispatch currently reaches — so a class that defines the name itself, whenever it does so, is never refused. `Core::ClassMethods#call` is `ActionState.result(new(**).tap(&:_run))` — ahead of both `new` and `_run`, and by then the class body has finished and the walk answers precisely. It is the only funnel there is: `lib/axn/core.rb:41` is the sole `_run` invocation in `lib/`, so no async, mounted or factory path reaches execution around it. This is the "before anything can consume it, not at declaration" allowance in `AGENTS.md`; the class, not the declaration, is what reveals the problem.

### 4. Mechanism: one shim module per class

`MethodShadowing.install_instance_deferrals(base, deferrals)` builds a single anonymous module per class and includes it:

```ruby
deferrals.each { |name, impl| shim.define_method(name) { |*a, **kw, &b| impl.bind_call(self, *a, **kw, &b) } }
base.include(shim)
```

Only classes with a collision get one, so the common case is byte-identical to today — no extra ancestor, no extra frame. `impl` is captured as an `UnboundMethod` at include time, which is also what makes the deferral honest: a later monkeypatch of the parent does not silently retarget it, and the wrapper is the one place a `bind_call` is unavoidable (a class-owned `UnboundMethod` cannot be `define_method`'d into a module).

Forwarding is `*a, **kw, &b`, which is exact on every Ruby this gem supports (3.2+): positional, keyword and block arguments each reach the target as the caller passed them, and a target taking a positional Hash keeps receiving one.

### 5. Naming which one is live, in either direction

Two class methods, both guarded by `conflict_for`. Neither edits an existing shim: a declaration only ever adds a wrapper to the DECLARING class's own module, which is what makes it structurally impossible for a subclass to change its parent's or its siblings' behaviour. `class ChargeCard < ApplicationAction` — where the deferral was recorded on `ApplicationAction` — is the ordinary Rails arrangement, and a mechanism that reached back to mutate the inherited shim would silently rewrite every sibling.

- `prefer_inherited :log` — asserts the deferral. Behaviourally a no-op when the deferral already happened, and it silences §6's warning for that name. It is documentation the reader of the class body can see.
- `prefer_axn :fail!` — stands axn's own implementation into the declaring class's module, above whatever the ancestry deferred to, leaving every other deferral and every other class untouched. This is the only way to reach axn's implementation once a parent owns the name, since `super` from the class body reaches the shim, not past it.

Each raises when the outcome it names cannot be delivered, which is one rule rather than two: `prefer_inherited :log` raises when no capture at or above the class holds `log` — nothing was deferred there to prefer (a typo, or a base class that lost the method), while `prefer_axn :log` on a class that never deferred is a satisfied assertion and stays silent. Both also raise on `:call`, `:_run`, `:initialize` (`:unsurrenderable`), on `:ambient_context` (sentinel) and on a Ruby-owned name, reusing `conflict_for`'s verdict and `describe`'s message. `prefer_inherited :fail!` is permitted, deliberately: it is a second spelling of the surrender `def fail!` already makes, internals survive it because they bind through `ActionState`, and the cost is confined to the author's own call sites (`outcome=exception, error="Something went wrong"` in place of a failure). Refusing the annotation while permitting the bare `def` would say the explicit form is the less trusted one.

### 6. The warning is keyed to the definer, not the class

One `Axn.config.logger.warn` per `(definer_module, name)` per process, naming the class it first fired for, the owner, and both resolutions. An `ApplicationService#log` inherited by fifty actions produces one line rather than fifty, which is what makes an unsilenceable-by-default warning tolerable; `prefer_inherited` suppresses it for a class that has said the deferral is intended.

It fires at the execution funnel rather than at `include Axn`, for the same reason §3's refusal does and one more: a line already written to the log cannot be unsaid by a `prefer_inherited` that runs later in the same class body, so silencing is only possible once the class body has finished. The cost is that an action never called never announces its deferral, and the two deferred checks share one seam instead of occupying two.

The warned-set is a record of a side effect already committed, so it is not reset by `Axn.config` reload or by a test helper that resets configuration — clearing it would re-warn for a decision the process already announced.

### 7. `NameOwnership` resolves through the shim

Post-deferral, `owner_of(klass, :log)` returns the shim. The verdict that falls out is already correct — an anonymous module is not in `SURRENDERABLE_OWNERS`, so `expects :log` raises rather than clobbering the parent's method — but the message is not: `owner_label` falls back to the method's `source_location`, which for the wrapper block points inside axn's own file and tells the author nothing.

The installer therefore registers `shim => { name => definer }`, and `owner_of` maps a shim owner back to the real one before classifying. `expects :log` then raises naming `ApplicationService`, which is the truth: the name is not axn's to surrender.

### 8. The rule gets written down

`AGENTS.md` gains both halves of §1 in one entry — the shared walk, the three parameters that differ, and the `Kernel#warn` justification for the `Object` truncation — so the class-side and instance-side rules are met together rather than as two checks a reader has to reconcile.

### 9. User-facing documentation

A new page under the **Advanced** sidebar section (`docs/advanced/inheritance.md`, registered in `docs/.vitepress/config.mjs` after "Conventions"), because this only concerns an author who includes Axn into a class that already has a hierarchy. Nothing goes into the intro or usage flow: the standard reader writes `class Foo; include Axn`, where `owner_within` returns `nil` for every name and none of this is observable.

The page covers what the author needs to decide, not the mechanism: that a name their own hierarchy owns wins over axn's helper, which 17 names that applies to, the two annotations for saying which one is live, and the fact that `call`/`initialize` raise instead of deferring because axn cannot yield a name Ruby and the executor dispatch. The class-side rule (`description`/`input_schema`/`output_schema`, PRO-2875) is undocumented on the site today and gets a short section on the same page, since a reader hitting one will hit the other.

## Testing

`spec/` (non-Rails) carries the matrix. `spec_rails/` only if a Rails-path difference appears; the plausible one is a base class under `ActiveSupport::Concern` or an `ApplicationService` in `app/`, which is coverage of the same walk.

The grid is *definer shape* × *name class*, asserting on observable outcomes:

- each of the 17 × a superclass `def` → the parent's implementation runs; the action still executes correctly end to end
- each of the 17 × a module included into the class *before* `include Axn` → same
- each of the 17 × a `def` in the class body, either side of `include Axn` → the class's own wins and `super` reaches **axn's**, unchanged from PRO-3062
- `log` × superclass `def` × a class-body `def log ... super` → the wrapper reaches the **parent** through the shim
- `call` × superclass `def`, with no class-body `call` → raises at `.call`, naming the owner; regression case for the silent `outcome=success` above
- `call` × superclass `def` × `Axn::Factory.build(superclass:)` → does **not** raise, and the factory's generated `call` runs
- `initialize` × superclass `def` → raises at `.call`
- `warn` × no definer → still reaches axn's logger, not `Kernel#warn`; `inspect`/`hash`/`then` × an `Object`-owned definition → axn defines as today
- `prefer_axn :fail!` after a deferral → `outcome=failure`; other deferrals on the class unaffected
- `prefer_inherited`/`prefer_axn` × `:call`, `:_run`, `:initialize`, `:ambient_context`, `:class` → raise at declaration with `describe`'s message
- `prefer_inherited :log` with nothing in the hierarchy owning `log` → raises
- `expects :log` on a class that deferred `log` → raises naming the **parent class**, not an anonymous module
- the warning fires once per `(definer, name)` across several classes under one base, and is not reset by a configuration reset
- no internal `NoMethodError` reaches a side channel in any of the above, asserted against the `on_ignored_exception` seam (PRO-3139)

## Out of scope

Class-level shadowing of `log` itself (a user's `def self.log`) stays untouched, as in PRO-3062.

Deferral for private internals (`internal_context`, `inputs_for_logging`) is refused by §2 rather than deferred, and no escape hatch is provided; a hierarchy that owns one of those names and needs axn to yield it is a report, not a configuration.
