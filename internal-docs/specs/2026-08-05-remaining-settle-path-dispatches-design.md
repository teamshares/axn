# Remaining caller-object dispatches on the settle path (PRO-3035)

Follow-up to PRO-3018 (PR #215), which closed the class of "a caller-supplied object read while axn settles or reports a failure can raise INSTEAD of the failure, costing the callbacks, the failure classification, or the whole `.call`." Every item here is pre-existing on `main` and was verified by probe rather than inferred. They were left out of that branch to keep it reviewable, not because they are benign.

Ticket: https://linear.app/teamshares/issue/PRO-3035

## Scope, after reconciling with PRO-3027

PRO-3027 ("Consolidate undispatched reflection into one module, and use it where the answer authorizes suppression") instructs reconciling its list with this one "rather than fixing the area twice". Its **item 2** — 11 sites where a caller-supplied exception's own `is_a?` decides whether it is absorbed or reclassified — is closed here, because three of those sites are already unavoidable for this ticket and one of them (`extensions.rb:77`) is the hole behind this ticket's sharpest item. Its **item 1** (the seven undispatched-reflection holders and the load-order constraint that forces the `Text`/`Rendering` split) stays there; this work adds exactly one bound reader to `NativeMethods` and collapses one duplicated binding.

Two items resolve to **no change**, with the position already recorded in the code rather than needing a new comment:

`Reflection::Values#projection_for`'s `respond_to?` calls stay dispatched. `values.rb:90-94` already states it: "`respond_to?` is deliberately NOT treated this way: 'do you claim to respond to this?' is genuinely the value's own answer to give, and overriding it is a supported idiom that a `method_missing`-backed proxy depends on." Hardening `owner_of` would remove zero foreign dispatches, since `projection_for` is gated on `respond_to?(:as_json)` anyway.

`MessageResolver#apply_join_proc`'s rescue set stays `StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR`. The existing comment already records the boundary — "Only what axn absorbs is caught, so a signal still propagates" — and the ticket's concern (a join Proc interpolating a hostile reason) is closed structurally instead, by handing the Proc operands it cannot be hurt by. See C1.4.

## C1 — Settle-path dispatches contained

### C1.1 `Extensions.owned_failure?` (`lib/axn/extensions.rb:77`)

`exception.is_a?(Axn::Failure)` becomes `Internal::Identity.kind?`. This sits ten lines below `swallowable?`'s comment explaining why that predicate must ask the hierarchy rather than the instance, and it is load-bearing for the next item: `_resolve_and_stamp_presentation` gates on `owned_failure?`, so hardening that method without this one fixes nothing.

`Axn::ValidationError.user_facing?` (`lib/axn/exceptions.rb:328`) is `exception.is_a?(self) && exception.user_facing?` — the instance's opinion gating a second dispatch to the instance. The `is_a?` becomes `Identity.kind?`. The `user_facing?` read stays dispatched: once the hierarchy has been established, calling axn's own reader on an axn-owned class is the same trade `facade_inspector#default_message?` already makes deliberately.

### C1.2 `_resolve_and_stamp_presentation` (`lib/axn/core/executor.rb:909`)

Delete `&& exception.respond_to?(:__present_as)` outright. With C1.1 in place, `owned_failure?` already guarantees an instance of a class whose ancestry defines `__present_as` (`Axn::Failure:127`, `Axn::ValidationError:335`), so the `respond_to?` is a redundant dispatch rather than a needed guard — and it is the closest structural analogue to the `respond_to_missing?` hole PR #215 closed, on a method called **bare** at `:875` inside `_settle_exception!` with no `best_effort` around it.

No `best_effort` wrapper is added. After this change nothing foreign is dispatched on that path: `@action.result.error` runs the resolver, which has its own guards, and `__present_as` normalizes through `NativeMethods.absent_value?`. Wrapping it would also be wrong in kind — the eager resolution is load-bearing (it must memoize while the action is still on the nesting stack, before `CarriedPresentation` is cleared), so it is not a side channel whose outcome nothing reads.

### C1.3 `MessageResolver#combine` (`message_resolver.rb:106`)

Today: `j.respond_to?(:call)` then `j.is_a?(String)`, both dispatched on the caller's `join:` value, both outside any guard. A `join:` object whose `respond_to?` raises escapes `.call` with a bare `RuntimeError` and `events=[]`.

New ordering, which removes both dispatches **and** the need for a callable probe at all:

1. `Identity.kind?(j, ::String)` → `joined(base, reason, j)`
2. `NativeMethods.absent_value?(j)` → `joined(base, reason, DEFAULT_JOIN)` (covers the unset `nil` join and `join: false`)
3. anything else → `apply_join_proc`, which already carries the guard

**No** behaviour change for a non-String, non-callable join. `MessageDescriptor.build:47` already rejects one at declaration (`ArgumentError: join: must be a String or a callable`), so `join: 123` never reaches `combine` at all — the third branch is only ever a callable, and the reordering leaves nothing falling through to a silent default.

Which narrows what the hardening is *for*, and the narrower claim is the honest one. Because the declaration guard has already asked both questions, what arrives at `combine` has answered them **once**. That is evidence about the first call and nothing more — the same bound that made a non-idempotent `Exception#exception` reachable after the object had already been raised once (`native_methods.rb`'s header: "an `#exception` that succeeds on its first call and raises on its second is not excluded by the object having been raised once"). So the reachable hazard is a `join:` whose answer is not idempotent, and the fix is to stop asking rather than to trust that the declaration passing settles it.

Note the declaration guard at `message_descriptor.rb:47` itself stays dispatched. It is a declaration guard on the self-correcting side of PRO-3027's boundary, and with `combine` routing every non-String through `apply_join_proc`'s guard, a value that lies to it is now contained rather than escaping.

### C1.4 `MessageResolver#apply_join_proc` (`message_resolver.rb:144`)

The Proc receives `fragment(base)` and `fragment(reason)` — UTF-8 Strings axn owns — instead of the raw objects. This was the intent of the interface all along; nothing relies on the current behaviour. It closes the ticket's second item structurally: a Proc interpolating a hostile reason can no longer dispatch that reason's `to_s`, because by then there is no hostile object left to interpolate. It also makes the documented use reliable, since `docs/usage/writing.md:264` advertises the Proc for "wrapping, recasing" and `reason.upcase` only works on a String.

Consistent with the render-at-the-join doctrine: the Proc's return value is what gets returned for that path, so the Proc **is** the join, and its operands are normalized exactly once before it composes them. The `DEFAULT_JOIN` fallback still routes through `joined`, which renders again — idempotent, so no double-transcoding.

Two smaller reads in the same method: the `Proc`/`Method` tests at `:146` and `:184` become `Identity.kind?`, and `result.present?` at `:157` becomes `!NativeMethods.absent_value?(result)` — the gem's single undispatched answer to "did the caller supply anything", already established as a String by the `kind?` on the same line.

### C1.5 `_override_parts` (`lib/axn/core/executor.rb:1305`)

`return [override] if Identity.kind?(override, ::String)` before `Array(override)`. A `user_facing:` **handler** returning a String subclass that carries `to_ary` currently loses its real text to `Kernel#Array`, so the field's validation message stands instead of the override. Contained today but asymmetric with the method's own comment, which argues the case only for the literal `when String` branch.

### C1.6 `_resolve_user_facing_override` (`lib/axn/core/executor.rb:1297`)

The `|| own` fallback is the one exit that skips `_override_part`, so for a non-UTF-8 validation message it disagrees by bytes with the `when true` branch, which renders the same `own`. One `_rendered_parts(list)` helper, used for both exits, so there is a single spelling.

### C1.7 `Configuration#on_exception` (`lib/axn/configuration.rb:249`)

`resolved_error == DEFAULT_ERROR` dispatches the caller value's own `==`, and `resolved_error` genuinely can be a caller object (`resolve_message` returns a standalone reason unchanged). Becomes `Identity.kind?(resolved_error, ::String) && MessageResolver::DEFAULT_ERROR == resolved_error`.

Both halves are required and the order matters. `String#==` dispatches the argument's `==` back when the argument is **not** a String, so putting axn's frozen literal on the left is not sufficient on its own; the `kind?` gate is what makes the comparison a byte comparison in C.

### C1.8 PRO-3027 item 2 — the remaining seven

Mechanical `exception.is_a?(K)` → `Identity.kind?(exception, K)`, verified behaviour-preserving in PRO-3027 (both forms ignore a class-side `===`, so user-supplied `fails_on` classes with their own `===` are unaffected):

`executor.rb:880`, `:887` (failure vs exception settlement) · `fails_on.rb:44`, `:50` · `matcher.rb:55`, `:65`, `:69` (handler matching) · `result.rb:85`, `:221`, `:233` (inspect label, user-provided message, standalone-failure classification).

Out of scope, per PRO-3027's own boundary: the ~163 input type checks (`value.is_a?(Hash/String/…)`) governed by the malformed-input doctrine, and the `klass.is_a?(Class/Module)` declaration guards.

## C2 — The dead ActiveRecord-relation branch (visible output change)

`facade_inspector.rb#format_for_inspect` tests `value.instance_of?(::ActiveRecord::Relation)`. Probed in the dummy app:

```
relation class:              User::ActiveRecord_Relation
instance_of?(AR::Relation):  false     ← the branch never fires
is_a?(AR::Relation):         true
```

So a relation falls through to `Identity.describe` → `inspect`, hydrating exactly the records the guard exists to avoid loading. Only a bare `ActiveRecord::Relation.allocate` satisfies `instance_of?`.

Fix: `Identity.kind?(value, ::ActiveRecord::Relation)`, and the hand-built `"#{value.name}::ActiveRecord_Relation"` becomes `Rendering.class_name(value)`, which the probe shows already produces that exact string — undispatched and rendered, removing a third dispatch (`value.name`) at the same time.

The trap to avoid: `Identity.class_of(value).name` returns `"ActiveRecord::Relation"`, because AR deliberately overrides `Class#name` on the generated relation class. Only `Module#to_s`, which `Rendering.class_name` uses, answers `"User::ActiveRecord_Relation"`.

This activates a dormant path, so it changes `inspect` output for **every** AR-relation exposure. Own commit, own CHANGELOG entry.

## C3 — Ownership and availability lookups

### C3.1 `ShapeValidator` (`shape_validator.rb:205` and `:182`)

`member.respond_to?(:user_facing)` and `member_method_call?`'s `member.respond_to?(:method_call)` — structurally identical, so both go in one pass (the ticket lists only the first).

Both become `Internal::ShapeGraph.read(member, name)`, which already exists for exactly this shape: "the value of `name` on `object`, or nil when nothing answers to it — for a caller that treats an absent reader and a nil one alike (a truthiness test, or a value that gets type-tested anyway)". It reads through bound `Object#public_send` with a name-matched `NoMethodError` check, so the `respond_to?` dispatch goes away.

Deliberately **not** an ownership predicate. `member.field` and `member.validations` are dispatched unconditionally two lines away, so an existence-in-the-method-table probe here would refuse an `OpenStruct` member whose other readers still work — an inconsistency, not a hardening. (`ShapeGraph.bound_method`'s own remaining `Object#method` hazard is filed as PRO-3055, not fixed here.)

### C3.2 `NativeMethods.public_instance_method` (new)

One bound reader, returning the `UnboundMethod` a **module** defines for a name, or nil:

```ruby
def self.public_instance_method(mod, name)
  return nil unless public_instance_method?(mod, name)

  MODULE_INSTANCE_METHOD.bind_call(mod, name)
end
```

Same absence policy as `method_owner` (nil, never a raise), same precondition as the existing `public_instance_method?` (the caller must have established `mod` IS a Module undispatched, or `bind_call` is a `TypeError`).

### C3.3 `Reflection::Schema` — three sites that disagree

`:743` (`framework_generated_reader?`) guards with `klass.respond_to?(:method_defined?)`, a dispatched stand-in for "is this a Module"; `:416` (`custom_serialization?`) calls `method_defined?` with no such guard; `:369` calls `public_method_defined?` with a dispatched `is_a?(Class)` above it. That disagreement is the ticket's `:721`-vs-`:749` item.

All three establish Module-ness undispatched and then run off C3.2's single lookup: `:369` needs only the boolean (`public_instance_method?`), `:416` needs `.owner`, `:743` needs `.source_location`.

Public-only is preserved at `:416` rather than widened to a bare `instance_method`. A **private** `as_json` would then count as custom serialization, but `serialize_value` calls `as_json` publicly and would never follow it — so widening would wrongly reject a provably-shaped Data/Struct. At `:743` the widening is answer-preserving either way (a private method's `source_location` is still the declaring file, never `GENERATED_READER_SOURCE_PATH`), but it uses the same lookup for consistency.

The undispatched Module test here is **not** an exception to PRO-3027's "the `klass.is_a?(Class/Module)` declaration guards are out of scope" boundary, and the distinction matters for anyone extending this later. Those guards are out because being lied to yields a declaration-time error, which is self-correcting. This one is a **precondition of a bound read**: `MODULE_INSTANCE_METHOD.bind_call` on a non-Module is a `TypeError`, which is exactly the replaced-verdict failure the bound read exists to prevent, so `public_instance_method?`'s own comment already requires the caller to have established it undispatched.

The neighbouring `Module#<`/`#<=`/`#==` comparisons at `:365-368` and `:401-402` (`k <= Hash`, `klass == Hash`, `klass < Data`) stay dispatched. They are declared-type checks on the self-correcting side of that boundary, and hardening them is not a precondition of anything this change adds.

## C4 — Adjacent

`TypeValidator.mock_value?` (`type_validator.rb:42`) reads `value.class.name`, letting a caller value's own `class` override decide whether type validation is waived. Becomes `Rendering.class_name(value).start_with?("RSpec::Mocks::")`. Probed: `"RSpec::Mocks::Double"` for `double`/`spy`, `"RSpec::Mocks::InstanceVerifyingDouble"` for `instance_double`. The `&.` disappears, since `class_name` always returns a String — and for an anonymous class its `#<Class:0x…>` answer takes the same branch `nil` did.

`NameError#name` is bound in two homes. `shape_graph.rb:470` open-codes `name.equal?(NAME_ERROR_NAME.bind_call(e))`, which is literally `Identity.name_error_for?(e, name)`. Repoint it, drop `shape_graph`'s constant, and leave the reasoning in Identity where the full comment already lives. No cycle: `Identity` requires only `internal/text`.

## C5 — `AGENTS.md`

The error-path rule is one line of 8,483 characters (line **135**, not the ticket's `:120` — the file has moved). The repo forbids hard-wrapping prose, so it splits into several one-line paragraphs. Its neighbours at `:131`, `:133`, `:137`, `:139`, `:141` are 1–2k each and stay as they are; the rules inside `:135` are what stopped being findable.

## Failure grid

Each row is a site; each column is how a caller's object unwinds. The cell is what it costs **today**, on `main`.

| Site | `respond_to?` raises | `to_s` raises (in `StandardError`) | `to_s` raises (outside) | overridden `==`/`is_a?`/`class` answers wrongly | `to_ary` on a String subclass | non-UTF-8 bytes both sides |
| --- | --- | --- | --- | --- | --- | --- |
| `combine` join test | escapes `.call` — but only for a join whose answer is not idempotent, since declaration already asked once | — | — | wrong join branch | — | — |
| join Proc interpolation | — | degrades to default join (correct) | escapes `.call` | — | — | `Encoding::CompatibilityError` → default join |
| join Proc return `present?` | — | — | — | blank treated as present, returned as the message | — | — |
| `_resolve_and_stamp_presentation` | escapes `_settle_exception!` after the exception is recorded but before `on_error`/`on_failure`/`on_exception` and the global report | — | — | presentation not stamped | — | — |
| `_override_parts` | — | — | — | — | override's real text dropped for the field's message | — |
| `_resolve_user_facing_override` fallback | — | — | — | — | — | raw bytes beside rendered ones |
| `on_exception` detail | — | — | — | wrong detail reported; a raising `==` costs the log line **and** the configured callback (both inside one `best_effort`) | — | — |
| the 11 `is_a?` sites | — | — | — | failure absorbed as a failure when it is a bug, or reported as a bug when it is a failure | — | — |
| `mock_value?` | — | — | — | type validation waived (test env only) | — | — |
| AR-relation branch | — | — | — | — | — | — (branch is dead; cost is hydration) |

Two mechanics the fixtures have to respect, both of which produced vacuously-passing specs during PRO-3018:

An `Encoding::CompatibilityError` needs non-ASCII on **both** sides of the join. A non-UTF-8 message against an all-ASCII template concatenates silently, so every encoding fixture must put non-ASCII in the surrounding prose too, not only in the caller's value.

"Raises outside `StandardError`" means outside `StandardError` **and** outside `SWALLOWABLE_BEYOND_STANDARD_ERROR` (`SystemStackError`, `ScriptError`). A fixture raising `NotImplementedError` is inside the swallowed set and proves the opposite of what it looks like.

## Commit plan

1. `owned_failure?`, `ValidationError.user_facing?`, the `respond_to?(:__present_as)` deletion, and PRO-3027 item 2's remaining seven — one commit, since they are one predicate class.
2. `MessageResolver` — `combine` reordering, rendered Proc operands, `absent_value?` for the return test.
3. `executor.rb` user-facing coercion — `_override_parts` short-circuit and the rendered fallback.
4. `configuration.rb` comparison.
5. `facade_inspector` AR-relation branch + CHANGELOG (visible output change).
6. `NativeMethods.public_instance_method` + the three `schema.rb` sites + `ShapeValidator`'s two.
7. `mock_value?` + the `NameError#name` collapse.
8. `AGENTS.md` split (docs only).

CHANGELOG: the AR-relation `inspect` change is the only user-visible one and is a plain fix, not `[BREAKING]`. The `join:` Proc now receiving Strings is worth a line as a fix as well, since a Proc reading a non-String attribute off `reason` would change behaviour. Everything else is `[INTERNAL]`.
