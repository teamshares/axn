# Integrity against instance-method shadowing (PRO-3062)

/ Linear: https://linear.app/teamshares/issue/PRO-3062/axn-integrity-against-instance-method-shadowing-internals-a-user

## Problem

`include Axn` defines methods on the user's class, and axn's own machinery then dispatches back through several of those same names. A user who writes `def result`, or declares a field whose reader takes one of those names, does not merely lose a helper — they corrupt the framework, and the corruption surfaces as a swallowed `NoMethodError` in a side channel rather than as a message naming the collision.

The ticket framed this as ~19 injected names. The probe found the surface is not a name list at all: a declared reader lands on the action **class** (`_define_field_reader`, `target: self`) and an exposure reader lands on the Result's **singleton class** (`facade.rb:40`). Both outrank `Object`. So the set a declaration can clobber is the entire method table of the receiver, axn's names and Ruby's alike.

Three defects share the root:

1. Internals dispatch through public, user-shadowable instance names — `result`, `internal_context`, `log`, `warn`, `execution_context`, `ambient_context`, `inputs`, `expose`.
2. `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` / `_FOR_EXPOSURES` (`contract.rb:1029-1053`) are hand-maintained, and guard only field declarations — a bare `def` is unguarded. Both lists are simultaneously too narrow (real holes below) and too wide — though only four of the seven flagged exposure entries are genuinely free names; the other three guard collisions that ownership alone can't see (below).
3. `class_attribute` without `instance_accessor: false` leaks a further 18 unprefixed public instance methods that neither list mentions.

## What the probe found

Every line below was run, not reasoned, on this branch.

The four breakages in the ticket reproduce. Beyond them:

```
expects :call         → ok? = true, outcome = success, and the user's `call` NEVER RAN
expects :class        → SystemStackError, 10,908 frames (reader → internal_context →
                        _build_context_facade → `class` → reader → …)
expects :internal_context → outcome = exception; poisons EVERY other field's reader,
                        because _define_field_reader's body dispatches `internal_context`
exposes :declared_fields  → NoMethodError `include?' for nil at result.rb:145,
                        swallowed into three separate side channels before it raises
exposes :deconstruct_keys → silently succeeds; `case result in {…}` then raises
                        ArgumentError: wrong number of arguments (given 1, expected 0)
exposes :hash         → result.hash returns the exposure; Results collide in a Set
exposes :class        → result.class returns the exposure; the Result cannot report its type
```

`expects :call` is the worst of these: the action reports **success** for code that never executed.

The lists are stale, but not the way they first look. `Axn::Result`'s real public API is exactly `__action__ __exposed_keys__ declared_fields deconstruct_keys elapsed_time error exception fail! finalized? message ok? outcome success`. Against that method table, `RESERVED_FIELD_NAMES_FOR_EXPOSURES` reserves seven names (`each_pair`, `ok`, `result`, `standalone`, `inputs`, `ambient_context`, `default_error`) while leaving `declared_fields` and `deconstruct_keys` — both load-bearing — unguarded. Only four of the seven — `each_pair`, `result`, `inputs`, `ambient_context` — are genuinely free: no method, and nothing else in the contract answers to them either. The other three guard collisions a method-table check can't see at all: `ok` is a key `deconstruct_keys` itself emits (not a method), `standalone` is a control kwarg `fail!`/`done!` read ahead of exposures, and `default_error` is owned by the inbound facade — a second receiver an exposed field is also implicitly readable through. A guard derived purely from `Method#owner` would have wrongly lifted all three; the actual guard also has to read the emitted key set and `.parameters`, not just the method table.

The user-facing helpers cannot be wrapped today. `delegate :log, *LEVELS, to: :class` runs inside `class_eval`, so `log` is owned by the user's own class; `def log(msg) = super(...)` raises `super: no superclass method 'log'`, and that `NoMethodError` is itself swallowed into the exception-report side channel. Every other injected name is module-owned; only the six logging names have this problem.

Two facts bound the design. A method defined in the class always beats an included module, so no include-order arrangement can protect a name a user might type — integrity can only come from not dispatching on the action at all. And `result` **is** user-facing: it resolves inside `on_success` hooks and inside `success`/`error` message procs, both verified.

The level aliases are used downstream (`os-app` calls `info` at `ops/preview_user_account_merge.rb:192,199` and `warn` at `slack/submit_shortcut_conversation.rb:87`), so they stay. Axn's `warn` is additionally a *public* override of the private `Kernel#warn`; removing it would silently redirect those calls to stderr.

Neither declaration order involving a user `def` is documented as an idiom. `expects :foo` followed by `def foo` (the wrap) works and is unaffected by anything here; `def foo` followed by `expects :foo` silently clobbers the user's method today and will raise under this design.

## Design

### 1. Internals dispatch on no instance name at all

A new `Axn::Internal::ActionState` (`module_function`) is the single funnel: `result(action)`, `internal_context(action)`, `inputs(action)`, `expose(action, …)`, `log(action, …)`, `execution_context(action)`, `ambient_context(action)`.

Its mechanism is the one `Axn::Internal::Identity` already establishes for caller-supplied collaborators, turned on the action itself: hold the real implementation as an `UnboundMethod` and `bind_call` it, so the invocation names a specific method object rather than dispatching a name the receiver can intercept.

```ruby
RESULT = Axn::Core::Contract::InstanceMethods.instance_method(:result)
def result(action) = RESULT.bind_call(action)
```

Verified: `bind_call` reaches the real implementation through both shadow forms — a user's `def result` and a generated `expects :result` reader — and preserves the `@__result` memoization, so it is the same object the sugar would have returned.

That is what makes it stronger than the two alternatives considered. Dunder twins (`__result`, `__log`, public names aliased onto them) are a smaller diff but still dispatch through instance names, satisfying the acceptance criterion by obscurity rather than by construction. Reaching through `@__context` and rebuilding the facades inside the funnel avoids dispatch too, but duplicates `_build_context_facade`'s construction logic and would have to be kept in step with it forever; `bind_call` calls that very method instead.

The executor's own `FAILURE_PRESENT_AS.bind_call` (`executor.rb:930`) is the same technique, adopted there for the same reason: "a bound call cannot be intercepted, so there is no availability question left to get wrong."

Call sites that move: `executor.rb:363, 495, 504, 639, 758, 760, 771, 927, 1086` (`result`), `executor.rb:1170, 1441, 1574` (`internal_context`), `configuration.rb:243, 244, 275, 290`, `extensions.rb:276, 323`, `internal/exception_context.rb:34`, `contract_for_subfields.rb:289`, `flow/handlers/invoker.rb:55`, `flow/handlers/matcher.rb:58, 78`, `flow/handlers/resolvers/message_resolver.rb:174, 197, 205`, and the body of `_define_field_reader` (`contract.rb:1881`).

`fail!`, `done!` and `forward!` route their `**exposures` through `ActionState.expose` rather than through the public `expose`, so shadowing `expose` costs the user their own convenience and nothing else.

Two of those call sites use `action.respond_to?(:result)` as a *type probe* — `configuration.rb:243` and `extensions.rb:274`, both of which legitimately receive `nil` or an action **class** rather than an instance. Shadowing defeats that probe precisely: a user's `def result` answers `true` and then returns a String, which is why `extensions.rb` has to re-probe the answer (`result.respond_to?(:finalized?)`) before trusting it. Both become an honest question — is this an axn action instance? — answered through `Internal::Identity`, and the defensive re-probes go with them.

**The one irreducible exception is `call`.** The executor must invoke the user's method (`executor.rb:232`). That is the sole name the framework cannot surrender, and the sole justification for a reserved entry on the expectations side.

### 2. `internal_context` leaves the public surface

Nothing user-facing needs it, and its only readers become the funnel. Pre-alpha, so it is removed outright per the tombstone convention rather than deprecated — `expects :internal_context` becomes an ordinary, working declaration.

### 3. User-facing sugar moves into modules

`delegate :log, *LEVELS, to: :class` moves out of `class_eval` and into `Logging::InstanceMethods`. That is the whole escape hatch, and it costs no new name: a user can wrap with `super`, or shadow the name and lose only the helper. No `axn` facade, no dunder aliases.

Everything user-facing is then module-owned and freely surrenderable: `result`, `inputs`, `expose`, `fail!`, `done!`, `forward!`, `log`, `debug`, `info`, `warn`, `error`, `fatal`, `default_error`, `default_success`, `execution_context`, `set_execution_context`, `clear_execution_context`, `ambient_context`.

### 4. The `class_attribute` leak closes

`instance_accessor: false` on `around_hooks`/`before_hooks`/`after_hooks` (`hooks.rb:8-10`), `internal_field_configs`/`external_field_configs` (`contract.rb:30`), `subfield_configs` (`contract_for_subfields.rb:20`), `_tags`/`_dimensions` (`tagging.rb:26-27`), `_auto_log_levels`, `_callbacks_registry`, `_messages_registry`, `_fails_on_matchers`, `_batch_enqueue_configs`, `_mounted_axn_descriptors`, and the `async.rb` set.

One instance-side read exists and must move first: `result.rb:145` calls `action.external_field_configs`, which is precisely why `exposes :declared_fields` explodes there.

### 5. One derived rule replaces both reserved lists

> A declared reader may take a name owned by axn's designated **sugar** modules — the user surrenders the helper. It may not take a name owned by anything else.

The check is a `Method#owner` query against the receiver's live method table, reusing the machinery `_reader_name_available?` / `_reader_owners` / `_inferred_reader?` already provide for inferred readers. Both constants are deleted; nothing is hand-maintained.

What replaces them is an enumeration of *modules*, not of names, and that is what takes it off the treadmill: adding a helper to an existing sugar module is covered automatically, and only introducing a whole new sugar module requires touching the set. Surrendering is the point — `expects :result` costs the user `result` inside their own hooks and message procs, which is the trade the declaration makes explicit.

**Expectations**, judged against the action class:

| owner | outcome |
| -- | -- |
| a sugar module (§3) | allowed — `expects :result`, `expects :log`, `expects :error` simply work |
| `Object` / `Kernel` / `BasicObject` | raise — closes `expects :class`'s `SystemStackError` |
| the user's own hierarchy, or a `def` earlier in the class body | raise, naming the owner |
| `call`, `_run` | raise — closes `expects :call`'s silent no-op success |

Distinguishing a user's `def` from an earlier declaration's reader (both owned by the class) uses the existing `_reader_owners` map; a duplicate declaration keeps reporting the clearer `DuplicateFieldError` it reports today.

**Exposures**, judged against `Axn::Result`: no sugar tier exists there, so any name Result answers to raises. This closes `declared_fields`, `deconstruct_keys`, `hash` and `class`, and lifts four of the seven stale restrictions — `each_pair`, `result`, `inputs`, `ambient_context`. The other three (`ok`, `standalone`, `default_error`) stay reserved: ownership alone can't see them, so the guard also has to check the key set `deconstruct_keys` builds and the control kwargs `fail!`/`done!`'s `.parameters` declare, and to ask the inbound facade as a second receiver.

Errors are `ContractViolation::ReservedAttributeError` as today, with a message naming the colliding owner and how to fix it (rename the field, or use `as:` to rename only the reader).

### 6. The pattern gets written down and enforced

`AGENTS.md` gains the rule — internals go through `ActionState`, user-facing sugar lives in a module, `class_attribute` gets `instance_accessor: false` — so a future edit does not reopen this.

Documentation alone is not the guard. A spec walks `lib/` and fails if any internal file dispatches a sugar name on an action receiver, so the funnel cannot silently regain a bypass.

## Testing

`spec/` (non-Rails) carries the whole matrix; `spec_rails/` only if a Rails-path difference appears.

The grid is *declaration form* × *shadowed name*, asserting on the observable outcome rather than on a name list:

- every sugar name × `expects :<name>` → the action runs correctly and the field reads
- every sugar name × `def <name>` → the action runs correctly; `super` reaches axn's implementation
- `call`, `_run` × both forms → raises at declaration naming the collision
- `Object`/`Kernel`-owned names (`class`, `hash`, `send`, `inspect`) × both surfaces → raises at declaration; specifically, `expects :class` no longer produces `SystemStackError`
- `Axn::Result`'s full public API × `exposes` → raises at declaration; `declared_fields`, `deconstruct_keys`, `hash`, `class` are regression cases with a named ticket reference
- the four genuinely-liftable names (`each_pair`, `result`, `inputs`, `ambient_context`) × `exposes` → declare and read cleanly; `ok`, `standalone`, `default_error` stay reserved as non-method collisions
- no internal `NoMethodError` reaches a side channel in any of the above — asserted against the `on_ignored_exception` seam from PRO-3139, so a swallowed internal error fails the test rather than printing a warning

## Out of scope

Instance-side deferral to a user-owned superclass name — mirroring `Axn::Core::MethodShadowing` on the instance side — is a separate ticket built on this one. It only becomes *safe* once §1 lands (today, declining to define `result` would break internals), and it carries its own unresolved design question: `Kernel` is in every ancestor chain and owns `warn`, so the rule must be scoped to ancestors before `Object` rather than reusing the class-side check as-is.

Class-level shadowing of `log` itself (a user's `def self.log`) is likewise untouched here.
