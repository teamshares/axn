# Make `confirmation:` enforce a confirmation (PRO-3023)

/ Linear: https://linear.app/teamshares/issue/PRO-3023/axn-confirmation-is-accepted-but-enforces-nothing

## Problem

`confirmation:` sits in `KNOWN_VALIDATION_KEYS`, so it declares cleanly — and it can never fire, in any spelling. A mismatched confirmation passes.

Three things have to be true at once for that, and all three are:

ActiveModel's `ConfirmationValidator#setup!` defines a real `attr_reader :<attr>_confirmation` on the one-off validator class axn builds per field, guarded by `klass.method_defined?`. `Axn::Validation::Fields.errors_for` assigns `@action` / `@validations` / `@reader` / `@config` / `@permit_method_call` and nothing else, so that reader answers `nil` on every call and `validate_each` returns before comparing. And because the reader is real, it shadows `Fields#method_missing`, so declaring a `<field>_confirmation` field of your own cannot supply the value either — the accessor wins over the fallback.

The docs promise the opposite. `docs/usage/writing.md:25` offers "any other ActiveModel validation", and `docs/reference/class.md:23` says arguments are processed "as if passed to `validates :foo, <...>` on an ActiveRecord model". One of those two things has to give: either the option works, or the promise carves out an exception. This design makes it work.

## What the probe found

Every line below was run, not reasoned. Measurements against `activemodel 7.2.2.2` and the current branch.

The defect, and that it survives every workaround:

```
expects :v, confirmation: true                          mismatch → ok? == true
  + expects :v_confirmation, optional: true             mismatch → ok? == true
validator_class.method_defined?(:v_confirmation)        → true
  instance_method(:v_confirmation).owner                → the one-off class itself
```

The fix is smaller than the ticket estimated. ActiveModel's generated `attr_reader` reads the **ivar**, so assigning it in `errors_for` is the entire runtime hook — `read_attribute_for_validation` is never involved:

```
ivar set to "b", value "a"    → ["V confirmation doesn't match V"]   (attribute: :v_confirmation)
ivar set to "a", value "a"    → []
ivar set to nil,  value "a"   → []
case_sensitive: false, "A"/"a" → []          "A"/"z" → mismatch
```

One existing helper resolves the companion at both depths, applying read-path transforms on the way:

```
resolve_value(v_confirmation)  → "a"   (from "  a  ", top-level, subfield? == false)
resolve_value(w_confirmation)  → "y"   (subfield under :h, subfield? == true)
```

`FieldResolvers::Extract#resolve_segment` reads Hash-like sources by key (`extract.rb:52`) and `Data` members from the member hash (`:83`) **before** reaching the gated dispatch branch (`:89`). So on a Hash, `Data`, or `ActionController::Parameters` source neither the base field nor its companion dispatches, and inheriting `method_call:` is a no-op. Only an object source reaches the gate, and there the base field's own read demands the permission first — measured on the shared resolution path (the relevant consumer is a subfield whose parent is a caller-supplied object; shape members are refused outright, see decision 6):

```
object source, method_call: true   → ok? == true
object source, no method_call      → "Refusing to resolve `v` by calling `#v` on Obj: …"
```

Real ActiveModel confirmation semantics, which decide the requiredness question below:

```
confirmation omitted        → valid? == true
confirmation explicitly nil → valid? == true
confirmation ""             → valid? == false   ("Password confirmation doesn't match Password")
confirmation mismatched     → valid? == false
n: 5 vs n_confirmation: "5" → valid? == false
```

The gated shape, written by hand, behaves exactly as intended with no cross-talk:

```
required base, nothing supplied → "Password is not a String"     (base's error alone)
required base, base only        → confirmation error
required base, both             → ok? == true
optional base, nothing supplied → ok? == true
optional base, base only        → confirmation error
optional base, both             → ok? == true
```

And the gate survives into the emitted schema when it is a Symbol:

```
if: :nickname  → "allOf": [{ "if": { "required": ["nickname"], … }, "then": { "required": ["nickname_confirmation"] } }]
if: -> { … }   → "required": ["nickname_confirmation"]        (clause dropped, over-requires)
```

## Decisions

### 1. The companion is implicit, on the `<field>_id` template

`expects :password, confirmation: true` declares a `password_confirmation` input. The author does not write it.

The alternative — requiring the author to declare the pair — was rejected because it fails the documented promise (Rails needs no companion declaration), and because it needs a "companion is missing" guard that cannot fire at declaration: `expects :password, confirmation: true` legitimately precedes `expects :password_confirmation`, so the check would have to defer to first use. The implicit companion dissolves that problem entirely; there is nothing to guard.

`model:` already establishes the pattern in this codebase. Its `<field>_id` companion is not injected by a generic mechanism — it is hand-threaded through five surfaces, each of which is the template for the corresponding confirmation surface (see the table below).

### 2. What the companion inherits from the base field

| Inherited | Why |
| --- | --- |
| `type:` | Keeps the emitted schema and the runtime in agreement about what the companion may be. Does not change outcomes — a type-mismatched confirmation already fails the comparison — only which error is reported. |
| `coerce:` | **Load-bearing.** `expects :count, type: Integer, coerce: true, confirmation: true` with a form post of `count: "5", count_confirmation: "5"` compares `5` against `"5"` and reports a spurious mismatch unless the companion coerces too. |
| `preprocess:` | Same failure, same reason: `preprocess: ->(s) { s.strip }` on the base compares `"a"` against `" a "`. Both sides of a comparison must live in the same space. |
| `method_call:` | An enabler, not a requirement. It is never consulted on a Hash/`Data`/`Parameters` source, and on an object source the base field's own read already required it — so the companion rides the permission the author granted for the same object. Precedent: `contract_for_subfields.rb:701` resolves an undeclared `<field>_id` off a possibly-object parent with `permit_method_call: config.method_call`. |
| `sensitive:` | Security-critical. A sensitive password whose confirmation logs in plaintext is a leak. Template: `redaction.rb:187` `_sensitive_field_keys`. |

| Not inherited | Why |
| --- | --- |
| `default:` | A defaulted companion would silently satisfy its own comparison. Must be actively excluded, not merely omitted. |
| `presence:` / `length:` / `format:` / other validators | The companion's only job is to be comparable. A constraint the base satisfies is one the matching companion satisfies by construction. |
| `allow_nil:` / `allow_blank:` / `allow_empty:` | Moot under the requiredness rule below. |

### 3. The companion is required exactly when the base field is present

Gated with a Symbol condition naming the base field:

```ruby
expects :password, type: String, sensitive: true, confirmation: true
#   ⤷ expects :password_confirmation, type: String, sensitive: true, if: :password
```

Three cases, and the gate gets all three right without a special case: an absent optional base closes the gate and demands nothing; an absent required base reports its own error alone, because the gate is closed there too; a present base of either kind demands the confirmation.

This is a deliberate difference from ActiveModel's default, and the justification is that AM's default exists to serve a constraint axn does not have. `password_confirmation` is a virtual `attr_accessor` on a persistent object: a record loaded from the database carries `nil` there forever, so erroring on `nil` would make `user.update(name: "x")` fail until someone re-typed the password. AM cannot distinguish "the form omitted this" from "nobody touched the password on this save". An axn call is one inbound message validated once — no loaded record, no second save, no virtual attribute persisting `nil` across a lifecycle — so inheriting the default would inherit a workaround for a problem that does not exist here.

It is also what the Rails guides tell you to write by hand: *"This check is performed only if `password_confirmation` is not nil. To require confirmation, make sure to add a presence check for the confirmation attribute."* So this is parity with Rails practice while differing from the ActiveModel default, and the difference must be stated wherever `confirmation:` is documented.

The measured cost: `conditional_requiredness_clause` (`schema.rb:669`) emits the exact `allOf` clause only for a Symbol gate referencing a plain declared field, and bails to unconditional `required` when the referenced field carries `model:`, a `default:`, or a `preprocess:` (`schema.rb:692`). So a base field with a `preprocess:` advertises its companion as unconditionally required while the runtime requires it only alongside a present base. That is stricter than runtime, which `schema.rb` already names the safe direction, and it is accepted here rather than worked around.

### 4. Reader name and wire key are derived separately

The wire key comes from the field name; the reader name comes from the (possibly aliased) reader. `expects :password, as: :pw, confirmation: true` yields a `pw_confirmation` reader reading the `password_confirmation` wire key. `model:` splits these the same way at `contract.rb:1409` (reader) and `:1412` (wire key).

### 5. An explicit declaration wins

If the author declares `expects :password_confirmation, …` themselves, that declaration is authoritative and the implicit one stands down. Both halves of this already have templates: `schema.rb:1042` (`prop[:properties][id_field] ||= subprop`) for the emitted property, and `_reader_name_available?` (`contract.rb:1375`) for the reader. This makes the implicit companion a superset of the explicit-pair design rather than an alternative to it.

### 6. `confirmation:` is rejected on `exposes` and on shape members

On `exposes`: an injected exposure would be a result property the action never sets, so it would resolve `nil` on every call and the check would never fire — the ticket's own defect, rebuilt. A confirmation pair is an inbound form concept.

On shape members: decision 3's gate cannot be written. A member's `if:` condition resolves against the **action**, not the element — `ShapeValidator#validate_members_of` threads the action deliberately, "so a member's Symbol/Proc arguments and if:/unless: conditions resolve against the ACTION, exactly as at the top level (a member condition is action-scoped, never element-scoped)". Measured, an injected `field :password_confirmation, if: :password` raises `undefined method 'password' for an instance of Axn::Validation::Fields::OneOff` on every call, while the same gate naming a real top-level field resolves fine. There is no member-scoped condition mechanism to reach a sibling member, and the nil-skip collapse (decision 9) is on the field pipeline, which members do not share.

The two alternatives were weighed and rejected. Injecting an unconditionally-required companion member is exact when the base member is required — an absent base already errors, so "required when present" collapses to "required" — but over-requires when the base member is `optional:`, putting the schema and the runtime in the loose-direction disagreement. Injecting an optional companion member would make `confirmation:` enforced-when-present at every level except inside a shape, where it would be enforced only when the caller happened to send it: a boundary an author cannot see from the declaration.

So it is refused at declaration, exactly as `model:` is (`_raise_member_model_unsupported!`, `shape_declaration.rb:434`) and for the same kind of reason — an option whose semantics need something a member structurally lacks. The message names the reason and the alternative: declare the pair as subfields (`expects :password, on: :payload`) to get the confirmation contract.

### 7. Requiredness resolves in a second pass, after all properties exist

Declaration order must not decide anything. `schema.rb:181-183` already resolves the generated `<field>_id`'s requiredness this way, explicitly "after all properties exist, so it's independent of declaration order", and the confirmation companion uses the same pass.

### 8. `nil_tolerant_validation?` keeps its `confirmation` carve-out

`validation/base.rb:130` stays as it is, because it remains correct: ActiveModel skips the comparison when the companion is `nil`, so a `confirmation` entry on the **base** field rejects no nil of its own. Only the justifying comment changes — from a claim that rests on the accessor always being `nil` (which this design ends) to the measured behaviour of a working validator. Requiredness of the *companion* is a separate question, answered by the gate in decision 3.

### 9. A missing companion reports one message, by narrowing `_type_rejects_nil?`

A gated required field reports two clauses for a `nil` where an ungated one reports one: `"Password confirmation is not a String and Password confirmation can't be blank"`. The cause is not the companion — it is `contract.rb:1793-1794`, which disqualifies the nil-skip collapse whenever the type entry is *effectively* gated, declaration-level gates included.

That guard is right about a gate the type entry carries **of its own** — a closed one skips the type check while the siblings still run, so their nil rejections become the only account of the nil and must not be relaxed. It over-reaches on a **declaration-level** gate, which opens and closes every validator on the declaration together, presence included: it changes whether an account is given, never whose it is.

The narrowing is to bail on the *presence of a nested gate key on any entry*, blank or not, rather than on effective gatedness. Blankness matters: AM's per-key merge lets a blank same-key nested override drop the shared gate for one entry alone, desynchronizing it from its siblings in the opposite direction — which is what makes key-presence, not `entry_self_gated?`, the correct test. This is the same predicate `schema.rb:685` (`entry_mentions_gate_key?`) already applies for the same reason.

Measured: with the narrowing, the full suite is 5151 examples / 0 failures, and the gated companion reports a single message. Trying it with `entry_self_gated?` instead fails three specs, all on the blank-nested-override case, which is what identified the correct predicate.

This is a general fix — every conditionally-required field in axn gains the one-message behaviour that unconditional ones already have — so it wants its own spec coverage rather than riding only on confirmation's.

## Surfaces to thread

Each row names the `<field>_id` implementation that is its template.

| Surface | `<field>_id` today | Confirmation analog |
| --- | --- | --- |
| Reader | `contract.rb:1385` `_define_model_id_reader`, deferring via `_reader_name_available?` | Reads the companion wire key; same deference |
| Companion value at validation | — | `errors_for` sets the AM-generated `@<field>_confirmation` ivar from `resolve_value(companion_config)` |
| Undeclared-input gate | `executor.rb:1393` `_model_id_top_level_keys` | Same shape, so tool calls under `reject_undeclared_inputs` accept it |
| Redaction | `redaction.rb:187` `_sensitive_field_keys` | One line; the security-critical one |
| Input schema | `schema.rb:1036-1047` + `model_id_property` | Emit the companion; requiredness via the second pass (decision 7) |
| Generated-key naming | `property_names.rb:519`, `:881` | So collision and renderability rules see the generated key |
| Subfield path | `contract_for_subfields.rb:695` `_define_subfield_model_id_reader` | Same, including the `method_call:` inheritance at `:701` |
| Ambient path | `ambient_context.rb:286` | Same |

## Where `confirmation:` is supported

| Level | Gate can name the base field | One message on a missing companion | Supported |
| --- | --- | --- | --- |
| Top-level field | Yes | Yes (decision 9) | Yes |
| Subfield, including ambient | Yes — resolves against the sibling's generated reader | Yes | Yes |
| Shape member | No — member conditions are action-scoped | No — separate pipeline | Refused at declaration (decision 6) |
| `exposes` | n/a | n/a | Refused at declaration (decision 6) |

## Out of scope

The sibling ticket [PRO-3022](https://linear.app/teamshares/issue/PRO-3022/axn-reject-a-nested-on-in-a-validator-entry-it-silently-validates) — a nested `on:` in a validator entry — is the same family (an option accepted at declaration that validates nothing) with a distinct root cause and a distinct fix.
