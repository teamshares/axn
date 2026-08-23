# Validators at a container position: one positional rule

Ticket: https://linear.app/teamshares/issue/PRO-3192/axn-validators-on-a-container-typed-field-runtime-and-schema-disagree

Predecessor: https://linear.app/teamshares/issue/PRO-3166/axn-recursive-of-containers-inside-containers (`internal-docs/specs/2026-08-19-recursive-of-design.md`) — found while scoping it, caused by none of it.

Successor: https://linear.app/teamshares/issue/PRO-3193/axn-should-an-of-bag-take-the-full-validator-set — blocked on this decision, and the owner of everything this spec pushes out of scope. Read *Scope: where the element-wise spelling lives* before implementing either.

## Problem

A validator other than `type:`/`of:`/`shape:` on an `Array`- or `Hash`-typed field lands somewhere no rule states, and the runtime and the emitted schema frequently disagree about where. Re-probed 2026-08-21 against `5e309e17` (ruby 3.3.6, activemodel 8.1.3.1), on `expects :f, type: Array, of: String, <validator>`:

| Declaration | Runtime | Emitted | Verdict |
| -- | -- | -- | -- |
| `inclusion: { in: ["a", "b"] }` | element-wise: `["b","a"]` ✅, `["a","zzz"]` ❌ | `{type: "array", enum: ["a","b"], items: {…}}` | the node is **unsatisfiable** — nothing is both an array and `"a"` |
| `inclusion: { in: [["a", "b"]] }` | rejects `["a","b"]` — whole-value is **unspellable** | `{type: "array", enum: [["a","b"]], …}` | emitted correctly, unreachable at runtime |
| `exclusion: { in: ["bad"] }` | `["bad"]` ❌ but `["ok","bad"]` ✅ | nothing | wrong under **any** reading |
| `format: { with: /a/ }` | matches the array's `to_s` — `["a"]` ✅, `["b"]` ❌ | nothing | constrains a Ruby `inspect` string |
| `numericality:` | nothing passes, at any container | nothing | unsatisfiable |
| `comparison:`, `acceptance:` | depends on the literal: a container-typed bound or `accept:` set works (`comparison: { equal_to: ["a"] }` accepts `["a"]`, `Hash#>=` and `Set#>` compare supersets), a wrong-typed one cannot | nothing | judged by their literals, not by key |
| `length: { maximum: 2 }` | array size ✅ | nothing (`minimum:` **does** emit `minItems`) | coherent; ceiling never emitted |
| `presence:`, `absence:`, `confirmation:` | whole-value ✅ | floor only | coherent |
| `uniqueness:` | raises on every call — `type: String` included | nothing | not container-specific; out of scope |

`ActiveModel::Validations::Clusivity#include?` (activemodel-8.1.3.1, `clusivity.rb:24`) is the whole cause of the first three rows:

```ruby
if value.is_a?(Array)
  value.all? { |v| members.public_send(inclusion_method(members), v) }
else
  members.public_send(inclusion_method(members), value)
end
```

For `inclusion` that reads as "every element is in the set". For `exclusion` the same `all?` is inverted by the caller (`if include?(...) then add error`), so it reads as "reject only when *every* element is forbidden" — an array carrying one forbidden element among legal ones passes. Nothing in axn opts into either; no test pins it and no doc states it.

## The rule

> **A validator constrains the value at the position it is declared at.**

Every position is named by the declaration that introduces it, and `of:` is how you descend one:

```ruby
expects :tags, type: Array, of: String, inclusion: { in: [["a", "b"], ["c"]] }        # the array itself
expects :tags, type: Array, of: { klass: String, inclusion: { in: ["a", "b"] } }      # each element
expects :meta, type: Hash,  of: { values: { klass: String, inclusion: { in: [...] } } } # each map value
expects :grid, type: Array, of: { klass: Array, of: { klass: String, inclusion: { in: [...] } } }
expects :status, type: String, inclusion: { in: ["a", "b"] }                          # unchanged
```

One word, one meaning, at every depth; what varies is only the position it was written at. The rule is already what `length:` (cardinality), `presence:`/`absence:`, `confirmation:`, and `inclusion:` on a `Hash` do today — `Clusivity`'s Array branch is the sole dissenter.

The alternative — set-shaped validators distribute over elements while size-shaped ones measure the container — was rejected on three grounds. It puts two targets in one namespace with nothing in the declaration to say which. It cannot reach a `Hash` without picking an axis by convention, which is the exact guess `MAP_OF_REQUIRED_MESSAGE` already refuses to make for `of:`. And it stops at depth 1: a map's `values:` axis and an element two levels down have no field-level slot to borrow, so the distributing reading is unavailable precisely where the grammar is otherwise complete.

## What changes

1. `inclusion:`/`exclusion:` compare the **whole value**, at every position, whatever the declared type. `[BREAKING]`
2. `format:` and `numericality:` are **refused at declaration** on a container-typed field. `[BREAKING]`
3. A value constraint no value of the declared `type:` could satisfy — an `inclusion:` set, an `acceptance:` `accept:` set, or a `comparison:` bound — is **refused at declaration**. `[BREAKING]`
4. `maxItems`/`maxProperties`/`maxLength` are emitted, mirroring the existing floor. Additive.
5. The projection invariant gains a satisfiability corollary; the positional rule is written down. Docs only.

### 1. Whole-value clusivity

`Axn::Validation::Base` already exposes axn's one-off validator classes as constants so they scope to axn's own validator classes rather than the host app's (`base.rb:13`), and `validates` resolves a validator by `const_get("#{key.camelize}Validator")` from the class being declared on (activemodel `validates.rb:121-124`). A constant on `Base` therefore wins over `ActiveModel::Validations::InclusionValidator` for every axn validation — top-level field, subfield, shape member, and `ContainerContents` position alike — with no monkey-patch and no reach into the consuming app. Verified by probe: with the constant in place, `inclusion: { in: [["a","b"]] }` on an `Array` field accepts `["a","b"]`, `type: String, inclusion: { in: ["a","b"] }` is unchanged, and the emitted `enum` needs no edit at all — reflection has been emitting the whole-value reading the entire time.

Two new validators in `lib/axn/core/validation/validators/` — `Axn::Validators::InclusionValidator` / `ExclusionValidator`, matching the namespace every existing one uses — both a two-line subclass over one shared module that overrides `Clusivity#include?` to drop the Array branch. A module included into each subclass rather than the override written twice: they are one behavior, and the module sits ahead of `Clusivity` in each subclass's ancestry, which is what makes the override reachable at all.

Scoped to axn's validators by construction, and deliberately **not** conditioned on the declared type. "The value at this position" is one reading or it is not a rule, and a runtime whose meaning depends on what the value happens to be at call time is a projection that cannot be written: the emitter never sees a value.

### 2. Refusing the validators that can only target a container's `to_s`

`format:` matches `value.to_s`, so on an `Array` it constrains `["a"].inspect` — satisfiable (`format: /a/` really does accept `["a"]`), meaningless, and unexpressible in JSON Schema, where `pattern` applies to strings. `numericality:` parses a numeric coercion, which no container has, so nothing passes whatever the options say.

`comparison:` and `acceptance:` are deliberately NOT refused by key, though an earlier draft of this design refused them and was wrong to. Their options can name a container, and then they work: `comparison: { equal_to: ["a"] }` accepts `["a"]`, `{ greater_than_or_equal_to: { "read" => true } }` accepts a Hash superset via `Hash#>=`, `{ greater_than: Set["a"] }` accepts a Set superset via `Set#>`, and `acceptance: { accept: [["a"]] }` accepts `["a"]` — all measured in bare ActiveModel. What is broken about them is a literal of the wrong type, which is a satisfiability question rather than a by-key one, so they are judged below alongside `inclusion:`.

Refused at declaration, in `_parse_field_validations` immediately after `_reject_validator_context_scope!` — the same tier (a declaration that cannot run coherently), before the tolerance push-down so the message quotes the author's own spelling rather than one carrying axn's merged keys.

The refusal fires only when **every** declared `type:` token is a container class, so `type: [String, Array], format: /a/` stays legal. That is the under-restricting direction: a field with no declared `type:` cannot be judged at declaration and simply gets the uniform runtime reading, which is a late diagnosis rather than a wrongly rejected declaration.

### 3. Refusing a value constraint that nothing of the declared type can satisfy

This is the guard that turns change 1 from a silent semantics flip into a teachable error: `type: Array, of: String, inclusion: { in: ["a", "b"] }` — today's element-wise spelling, and the one existing users have written — becomes a declaration error naming the position they meant, instead of a field that quietly rejects every value.

Membership is judged by `Validators::TypeValidator.value_matches?`, the matcher the runtime type check itself uses, so the guard cannot disagree with the runtime about the same pair. It fires only when the set is a literal, in-memory Array or Set (the same side-effect-free reading `Base.set_includes_nil?` and `Schema.inclusion_enum_values` already do — a Symbol, a Proc or an `ActiveRecord::Relation` is unknown and stands down) and only when every declared token is a real Class or Module (a `:boolean`/`:uuid`/`:params` pseudo-token stands down).

The literal-set read is currently spelled twice — `Base.set_includes_nil?` for nil membership and `Schema.inclusion_enum_values` for the emitted `enum`. This adds a third consumer, so it extracts **two** readers rather than growing a parallel one: `Base.declared_set_collection` answers WHERE the set lives (`in:`/`within:`, or the bare shorthand) and serves all three, while `Base.literal_set_members` answers which members may be judged side-effect-free and serves the two membership consumers. Not one reader, because reflection's admissibility rule is deliberately narrower than membership's — it maps the members into the emitted document, so it takes an exact `Array` where a membership question also accepts a `Set` or a Hash's keys.

The same judgment serves `acceptance:` (its `accept:` set, defaulting to ActiveModel's own `["1", true]` when the entry names none) and `comparison:` (its bound). Three validators, one question, because all three compare the value against literals the declaration supplies and all three break the same way when nothing of the declared type could satisfy those literals.

`other_than` is excluded from the comparison keys judged. It is an inverted operator, so a wrong-type bound makes the check always PASS rather than always fail — measured: `comparison: { other_than: 1 }` accepts `["a"]`. That is vacuous rather than unsatisfiable, which is a different defect and the same reason `exclusion:` is not judged here either.

Two widenings keep the matcher from refusing legal work, and both are load-bearing. A literal whose class is a **content-comparing root** the declared type descends from can be satisfied — `SubArray.new([1]) == [1]` is true — so the literal's class must BE one of `Array`/`Hash`/`String`/`Set` and the declared klass must descend from THAT SAME root; binding the two halves independently would pair a String literal with an Array subclass, and gating on ancestry alone would let a bare `Object.new` literal (an ancestor-instance of every declared type) disarm the guard universally. And a literal in the same **cross-comparable family** — `[Numeric]`, or `[Date, Time, DateTime]` — compares across classes, so `type: Float, comparison: { greater_than: 0 }` and `type: Integer, inclusion: { in: [1.0] }` stand down. Unrelated classes do not cross-equate (`["1"].include?(1)` is false), which is what keeps judging them safe.

A `Range` set is judgeable only at a container position, by its bounds: `(1..5).cover?([1, 2])` is false because `<=>` is nil across unrelated classes, while `(["a"]..["z"])` is left alone because its bounds are Arrays. Not generalized past containers, because `(1.0..5.0).cover?(3)` is true.

**This is deliberately not container-only.** `type: Integer, inclusion: { in: ["1", "2"] }` is unsatisfiable for exactly the same reason and is exactly as broken; scoping the guard to containers would leave a structurally identical hole open on every other type. It does mean the guard can newly reject declarations in downstream apps that are already dead code — the blast radius was measured across every consumer (os-app, buyout-app, axn-mcp, axn-ruby_llm, data_shifter, slack_sender, invoice-app) and is zero: no container-typed field carries `format:`/`numericality:`, and every `inclusion:` is untyped, tolerance-bearing, or type-consistent.

### 4. The ceiling emission

`declared_length_floor` has no twin, so `minItems`/`minProperties`/`minLength` emit and the ceiling never does — at every position, container or scalar. Add `Base.declared_length_ceiling` + `Base.emittable_length_ceiling?` beside them, reading the same `declared_length_checks` (so `is: 2` yields both bounds, an `in:`/`within:` range yields both, and an exclusive end still counts one less), and a `size_ceiling_key_for` mirroring `size_constraint_key_for` in `apply_size_constraints!`, including the per-branch `anyOf` walk.

Conservatism mirrors the floor exactly: an `Integer` bound only, `:unverifiable` for a Symbol/Proc AM resolves per call, and `Float::INFINITY` uncarryable. Emitting a ceiling only shrinks the schema-valid set, so it preserves the documented direction by construction — the same move `apply_size_constraints!` already made for the floor.

`absence: true` could emit `maxItems: 0`, which is exactly what it means. Same gap, different validator, and it drags in the `allow_empty:` axis — left out on purpose, recorded below.

### 5. What goes in the docs

An earlier draft of this spec asserted a projection invariant backwards, and the correction is worth keeping in the record because the wrong version sounds just as plausible: it claimed the schema may accept what the runtime rejects but never the reverse. The standing invariant is the opposite, and is stated twice already.

`docs/reference/class.md:270` — "It reflects every conditional field **as if every gate were open** … so the schema may be *stricter* than the runtime …, but never looser."

`docs/recipes/authoring-tool-adapters.md:117` — "**Reflection is best-effort and biased *stricter* than runtime** — a call that follows the schema won't be schema-rejected." With two documented looser exceptions: an invalid literal `default:`, and a gated required subfield whose condition does not reference its own parent's presence.

So schema-valid ⇒ runtime-valid, and nothing here changes that. What the `enum`-on-array row exposes is that the invariant is vacuously satisfiable: `{type: "array", enum: ["a","b"]}` admits **no** values, so it is trivially "not looser" while telling a caller nothing it can act on. Hence the corollary, which is the whole doctrinal addition:

> **The projection of a satisfiable contract must itself be satisfiable.** "Biased stricter" licenses a node admitting fewer values, never one admitting none — and an unsatisfiable node is the signature of the runtime and the emitter disagreeing about what a validator targets.

Under the positional rule that node becomes unproducible: the declaration is refused before any projection exists. The corollary goes in `AGENTS.md` beside the guards-and-projections bullet, with the case study in `internal-docs/agent-notes/guards-and-projections.md`; the positional rule goes in `docs/reference/class.md` next to the `of:` grammar.

## The failure grid

Every validator key in `KNOWN_VALIDATION_KEYS` at a container position, before and after. "Refused" means at declaration. Probed values: `[]`, `["a"]`, `["a","b"]`, `["1"]`, `[1]` for an Array; `{}`, `{"k"=>"v"}`, `{"k"=>1}` for a Hash.

| Key | Runtime before | Runtime after | Emitted before | Emitted after |
| -- | -- | -- | -- | -- |
| `type` `of` `shape` `coerce` `model` `validate` | position's value | unchanged | `type`/`items`/`properties`/`additionalProperties` | unchanged |
| `presence` | whole value | unchanged | floor | unchanged |
| `absence` | whole value (`[]` only, needs `allow_empty:`) | unchanged | floor | unchanged (`maxItems: 0` deferred) |
| `confirmation` | whole-value equality | unchanged | companion property | unchanged |
| `length` | container size | unchanged | floor only | **floor + ceiling** |
| `inclusion` | element-wise on Array; whole-value on Hash | **whole-value everywhere** | `enum` (whole-value) | unchanged — the runtime moves to meet it |
| `inclusion` with a set matching no declared type | rejects everything | **refused** | unsatisfiable node | nothing emitted |
| `exclusion` | rejects only when *every* element is forbidden | **whole-value everywhere** | nothing | nothing (see below) |
| `format` | the container's `to_s` | **refused** | nothing | n/a |
| `numericality` | nothing passes | **refused** | nothing | n/a |
| `comparison` `acceptance` | depends on the literal | **judged by their literals** — refused only when no value of the declared type could satisfy the bound or `accept:` set | nothing | nothing |
| `uniqueness` | raises at every position | unchanged — separate ticket | nothing | unchanged |
| `if` `unless` `message` `strict` | shared options, not validators | unchanged | per existing gate rules | unchanged |

`exclusion` still emits nothing, and that is now on the record rather than by omission: `not: { enum: [...] }` is the honest spelling (the emitter already uses that shape at `schema.rb:725`), but an unemitted constraint is looser than the runtime, which is the direction the two documented exceptions already occupy, and adding it is a projection widening with no bearing on the positional rule. Booked below.

## Scope: where the element-wise spelling lives

The cost of the positional rule is that between this change and PRO-3193, the only element-wise spelling is a `validate:` lambda that reflects nothing:

```ruby
expects :tags, type: Array, of: String,
        validate: ->(v) { "must contain only a or b" unless v.all? { |e| ["a", "b"].include?(e) } }
```

Widening the `of:` bag to carry `inclusion:`/`exclusion:` in this change would give the refusal a first-class destination on the same commit. Measured against the code, that slice is larger than it looks and it is **PRO-3193's**, in four parts that ticket already enumerates: the bag's validator keys have to reach `ContainerContents` (today `OfValidator#inner_contract_validations` picks out `:of` and `:shape` only, so a whitelisted-but-unpassed key would declare cleanly and enforce nothing — the exact silent-ignore hole PRO-3165 closed); `enum` has to be pushed into `items` and `additionalProperties`; a `keys:` axis carrying a set is what earns `propertyNames`, which PRO-3165 deliberately emits nothing for; and "which validators are meaningful at an unnamed position" is a whitelist PRO-3193 owns deciding.

Doing two of those keys here forces a partial answer to the fourth and pre-commits the emission mapping for the other six, which PRO-3193 would then have to retrofit. **Recommendation: ship the positional rule alone, and let PRO-3193 — unblocked the moment this lands, and already holding the machinery — deliver `of: { inclusion: … }` as its headline.** Refusal messages accordingly name `validate:` as the spelling that works today and name the position (`of:`, an axis) as the *place* the constraint belongs, without promising a key that would raise.

**Decided 2026-08-21: the rule ships alone.** The joint landing (this change plus the `inclusion:`/`exclusion:` slice of PRO-3193) was coherent but bigger, and it needed PRO-3193's whitelist decided here. PRO-3193 has been updated with what it now inherits: the positional rule as its premise, the destination obligation the refusal messages create, and the four parts of the slice measured above.

## Out of scope, recorded

- **`uniqueness:` raises on every call, at every position**, `type: String` included. Not container-specific, not this rule's business, and a real defect. Needs its own ticket.
- **`expects :f, type: Array, absence: true` accepts nothing** — the default non-emptiness floor rejects `[]`, `absence` rejects everything else — while emitting `minItems: 1`. An unsatisfiable *contract*, so it belongs with the PRO-2889 contradiction detectors, not with a projection rule. Needs its own ticket, and `absence` → `maxItems: 0` rides with it.
- **`exclusion` emission** (`not: { enum: [...] }`). Looser-than-runtime, deliberately, per the grid above.
- **The `of:` bag widening** in every part: PRO-3193.

## Breaking changes

Three, all `[BREAKING]`, all pre-alpha-6 and therefore removals rather than deprecations (`internal-docs` tombstone convention, PRO-2927):

1. `inclusion:` on an `Array`-typed field stops meaning "every element". The overwhelmingly common spelling of it becomes a declaration error (change 3), so the failure is loud at boot rather than silent at call time — but a set whose members happen to be arrays silently changes meaning, and a set read dynamically (a Symbol or Proc source) cannot be judged at declaration and changes meaning silently too. Both belong in the CHANGELOG entry.
2. `exclusion:` on an `Array`-typed field stops meaning "reject when every element is forbidden". Its old behavior was wrong under every reading, so there is nothing to migrate *to* — a field relying on it was not enforcing what it claimed.
3. `format:`/`numericality:` on a container-typed field, and an unsatisfiable `inclusion:`/`acceptance:`/`comparison:` literal on **any** type, now raise at declaration. Every one of them enforced nothing achievable before, so the fix is to delete the option, correct the literal's type, or move the constraint to the position it was meant for.

`CHANGELOG.md` has a live `## Unreleased` section (`v0.1.0.pre.alpha.5.1` is the newest tag, and alpha-5 is a shipped heading) — entries go there, under `### Changed` for 1–2 and `### Fixed` for the emission gap.

## Files

| File | Change |
| -- | -- |
| `lib/axn/core/validation/validators/inclusion_validator.rb` (new) | whole-value subclass |
| `lib/axn/core/validation/validators/exclusion_validator.rb` (new) | whole-value subclass |
| `lib/axn/core/validation/validators/whole_value_clusivity.rb` (new) | the shared `include?` override, beside the validators that include it |
| `lib/axn/core/validation/base.rb` | expose both constants; `literal_set_members`; `declared_length_ceiling`; `emittable_length_ceiling?` |
| `lib/axn/core/contract.rb` | the two new declaration refusals in `_parse_field_validations`, beside `_reject_validator_context_scope!` |
| `lib/axn/internal/reflection/schema.rb` | ceiling emission in `apply_size_constraints!` + the `anyOf` branch walk; route `inclusion_enum_values` through `literal_set_members` |
| `lib/axn/core/validation/validators/validate_validator.rb` | its guard message advises `inclusion: { in: [...] }` as the fix, which is now refusable at a container position — needs a position-aware branch |
| `spec/axn/core/validations/container_position_validators_spec.rb` (new) | the failure grid above, row by row |
| `spec/axn/internal/reflection/schema_spec.rb` | ceiling emission, floor/ceiling together, `anyOf` branches, `:unverifiable` and `Float::INFINITY` stand-downs |
| `AGENTS.md`, `internal-docs/agent-notes/guards-and-projections.md`, `docs/reference/class.md`, `CHANGELOG.md` | the rule, the corollary, the grammar, the entries |

## Testing

TDD per `CONTRIBUTING.md`: the grid rows are the failing tests, written before any of the five changes.

The grid is the spec for `container_position_validators_spec.rb` — every row asserted at three levels (does it declare, what does it accept, what does it emit), for an `Array` and a `Hash` position, plus a scalar control per row proving the change did not reach a scalar field. The `inclusion` rows additionally assert the runtime and the emitted `enum` agree on the same value, which is the invariant the whole ticket exists to restore.

Beyond the grid: the whole-value change must not disturb `nil_accepted?` (a set containing nil admitted nil before and after, since a nil was never an Array and never took `Clusivity`'s Array branch); the constant shadowing must be proven to reach a **subfield** and a **shape member** and a `ContainerContents` position, not only a top-level field; and the declaration guards need the negative controls that keep them under-restricting — a union type carrying one scalar, an undeclared type, a pseudo-type token, and a dynamically-sourced set must each still declare cleanly.

`bundle exec rspec`, `spec_rails` (`BUNDLE_GEMFILE=Gemfile bundle exec rspec` from `spec_rails/dummy_app`), and `bundle exec rubocop` before claiming any task done.
