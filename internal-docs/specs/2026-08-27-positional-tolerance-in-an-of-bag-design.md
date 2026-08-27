# Positional tolerance in an `of:` bag

PRO-3225. Residue 1 of PRO-3166, carried by PRO-3193 and split out of it after measurement.

## Why

`of:` names what is inside a container. Since PRO-3193 the bag takes value validators, so "every element is a two-letter country code" is sayable. "…or `nil`" is not, and neither is "…or blank".

Three cases hide under "nil elements". Case 1 — nil elements with no other validator — is already spellable as `of: { klass: [String, NilClass] }`. Cases 2 and 3 have no spelling at all:

```ruby
expects :codes, type: Array, of: { klass: [String, NilClass], format: /\A[A-Z]{2}\z/ }
call(codes: ["AB", nil])   # => "F element at index 1 is invalid"
```

A union widens only the type check. ActiveModel runs every other validator on `nil` regardless — measured on bare AM with no flags, `format:` reports "is invalid", `length: { minimum: 2 }` "is too short", `inclusion:` "not included", `numericality:` "is not a number". So the union says `nil` is legal at that position and `format:` says it is not. Blank elements are worse: `""` *is* a String, so no type token reaches it, and `inclusion:` can list `nil` but cannot express "any two-letter code **or** blank".

`allow_nil:`/`allow_blank:` are the only thing in ActiveModel that means "skip this position's other checks for this value", which is why cases 2 and 3 have no alternative.

## What the measurement changed

PRO-3193 deferred this on the finding that the tolerance push's per-entry copies are the **only** record of a field's tolerance, and that exempting `:of` from the push moves eight examples including a published downstream contract. Both halves of that are still true. What the ticket got wrong is the price of the other design.

**Measured 2026-08-26, full suite: 7251 examples, 3 failures.** The patch replaced the tolerant branch's per-entry copies with the pair stated once at the top level of `validations`:

```ruby
# before — the pair copied into every entry
validations[key] = { allow_blank:, allow_nil: }.merge(normalize(v))

# after — stated once, where ActiveModel's own defaults tier reads it
validations.merge!(shared_options)
validations[:allow_blank] = allow_blank
validations[:allow_nil]   = allow_nil
```

`Base.nil_accepted?` needed **zero changes**. It already strips the shared options out of the entry set and hands them to `nil_tolerant_validation?` as the `declaration_options` tier, and `effective_entry_options` merges that tier under each entry exactly as `validates` does (`defaults.merge(_parse_validates_options(options))`, activemodel 7.2.2.2). The eight examples the ticket measured were measuring a *different* change — exempting `:of` while leaving the pair nowhere. Put the pair where AM's defaults tier already reads it and the entries do not need copies at all.

`optional?` stayed true, every emitted schema was byte-identical, and `spec/downstream_contracts/axn_mcp_interface_spec.rb` passed untouched. The three failures are in "Consequences" below.

And the bag came out clean — `{klass: Integer, container: Array}`, no keys axn wrote — which is the whole unblock.

**The second measurement removes the migration.** `allow_nil:`/`allow_blank:` in an element bag has no observable effect today. Same declaration with and without, singly and together, on a required and an optional field, across seven payloads:

```
of: { klass: String, format: /\A[A-Z]{2}\z/, … }    nil  []   ["AB"]  ["AB",nil]  ["AB",""]  ["ab"]  [1]
  bag as-is                                          NO   NO   ok      NO          NO         NO      NO
  bag + allow_nil: true                              NO   NO   ok      NO          NO         NO      NO
  bag + allow_blank: true                            NO   NO   ok      NO          NO         NO      NO
  bag + both                                         NO   NO   ok      NO          NO         NO      NO
```

Identical verdicts, identical `optional?`, identical emitted schema in all four rows. ActiveModel *does* read the pair as a field-level skip in `EachValidator#validate`, but `of:` requires exactly `type: Array` or `type: Hash` (`_declared_of_container!` refuses a union), so the container's own type check rejects a `nil` field before the skip can matter, and a blank field (`[]`, `{}`) has no positions to iterate either way. The skip is unreachable, not merely harmless.

Nothing can depend on a no-op. So giving these keys their positional meaning is **not a breaking change**, and the separate positional keyword PRO-3225 proposed as design 4 is unnecessary.

## Decision

Design 1, plus the bag taking the tolerance vocabulary a **named** position already takes.

A shape member accepts all three spellings today, with the granularity the names imply — measured on `field :code, type: String, format: /\A[A-Z]{2}\z/`:

```
member optional: true        "AB"=ok  nil=ok  ""=ok  "ab"=NO
member allow_nil: true       "AB"=ok  nil=ok  ""=NO  "ab"=NO
member allow_blank: true     "AB"=ok  nil=ok  ""=ok  "ab"=NO
```

An `of:` bag takes the same three, meaning the same things. That is the rule: **a bag position is held to the same tolerance vocabulary as a named member, because both describe one position's value.** No new keyword, no refusal, nothing to migrate.

The designs not taken. **Design 2** (push under a derived `container_field_tolerance:`) and **design 3** (preserve the author's pair under a derived key at push time) both add a second spelling of one fact to work around a push that, measured, costs 3 examples to fix properly; design 3 additionally has to survive the declaration walk's second pass over a shape member's bag, which runs *after* the push, so re-deriving there captures axn's values as the author's and silently widens the contract. **Design 4** (refuse the pair, introduce a positional keyword) needs the push to stop writing into `of:` anyway — which is design 1 — and its refusal is now known to be refusing a no-op.

## Part A — move the tolerance record to the top level

`_parse_field_validations`, tolerant branch. The pair is stated once on the declaration instead of copied into each entry. `validates` then applies it to every validator through its own defaults tier, which is where `nil_accepted?`, `effective_entry_options` and the emitter already look.

One exemption has to be carried across. `_tolerance_exempt_validator?(:confirmation)` keeps `confirmation:` out of today's push, because its subject is the *relationship* between base and companion, not the base's value: a supplied companion contradicting a blank base is a mismatch the caller must see. A top-level pair reaches it through AM's defaults, so the exemption inverts — the entry is given an explicit `allow_blank: false, allow_nil: false` that overrides the declaration tier per key, which is the merge order `validates` gives for free.

```ruby
validations.keys.each do |key|
  v = validations[key]
  next unless v
  next unless _tolerance_exempt_validator?(key)

  validations[key] = Axn::Validation::Base.normalize_validator_options(v)
                                          .merge(allow_blank: false, allow_nil: false)
end
```

Two downstream reads of the pair need checking and, measured, both already work:

* `_apply_nil_skip_to_non_type_validators!` still no-ops on a tolerant field. It gates on `_type_rejects_nil?`, which resolves the type entry through `effective_entry_options(raw, _shared_validation_options(validations))` — so a top-level `allow_blank: true` stands it down exactly as an in-bag one did.
* The declaration guards that take `tolerance: { allow_nil:, allow_blank: }` explicitly (`_reject_unsatisfiable_value_constraints!`, `_reject_vacuous_value_constraints!`) are unaffected: those are kwargs, read before the branch runs.

### Consequences

**`recursive_of_spec` "writes the tolerance pair onto the map bag and never into an axis"** pins the mechanism being replaced. It is rewritten to pin the new one: the pair lands at the top level of `validations` and never inside a bag, at either position.

**Two `confirmation_spec` examples.** The implicit companion inherits `config.validations.slice(:type)`, so with the pair at the top level it no longer inherits the base's tolerance. An `allow_nil:`/`optional:` base's companion then reports `"Password confirmation is not a String"` where it reported `"…can't be blank"`.

This is a consolidation, not a loss. Requiredness is still enforced — the companion's own gated `presence: true` is untouched — but the clause that reports it is now the type's, via `_apply_nil_skip_to_non_type_validators!`: the companion's inherited `type: { klass: String }` rejects nil, so the nil-skip relaxes its `presence:` and the type error stands alone. That is *already* the behaviour for a strictly-typed base, pinned two examples earlier in the same file ("requires the companion once there is something to confirm" expects exactly `"is not a String"`). After this change all three typed base shapes report identically, and an untyped base still reports `"can't be blank"` because it has no type to inherit.

It also corrects a stated claim: `_confirmation_companion_configs`' comment says the inherited tolerance "is inert on the companion". It is not — it is what selects which clause reports. The comment is rewritten to say the companion inherits the type *without* the base's tolerance, and why.

The alternative — have the companion inherit the top-level pair too, preserving both messages — is one line and is deliberately not taken: it would reintroduce the coupling design 1 dissolves, for a message distinction the file's own neighbouring example already contradicts.

## Part B — the bag reads its own tolerance

Once the bag is author-only, its keys can mean the position.

### Grammar

`optional:` joins `OF_OPTION_KEYS` and is canonicalized into the pair at declaration, mirroring `_parse_field_configs`' own `allow_blank ||= optional`, so nothing downstream reads three keys where the field reads two. Idempotent, so the walk's second pass over a shape member's bag is a no-op.

`AXIS_INERT_OPTION_KEYS` narrows. Today it is `shared_validation_option_keys - %i[on strict]` = `[:if, :unless, :allow_blank, :allow_nil, :except_on]`; the two tolerance keys come out, leaving `[:if, :unless, :except_on]`. The refusal existed because an axis bag is never handed to ActiveModel, so anything written there is dropped — but that reasoning is about *AM* reading the bag, and after this change `OfValidator` reads the tolerance itself. So the axis becomes expressive rather than more restricted:

```ruby
expects :m, type: Hash, of: { keys: { klass: Symbol },
                              values: { klass: String, allow_nil: true } }
# today: ArgumentError "of: values: does not support allow_nil:"
```

`if:`/`unless:`/`except_on:` keep being refused at an axis, because nothing reads a gate there and the reasoning genuinely does still hold for them.

### Runtime

`OfValidator`. `PositionContract` gains the position's tolerance, read in `position_contract` off the bag alongside `klass:`/`message:`, so it is resolved once per declaration like everything else there. `validate_position` stands the whole position down — type check *and* contents descent — which is what `optional:` does at a named member:

```ruby
def validate_position(record, attribute, contract, value, position)
  return if contract.tolerates?(value)
  # …unchanged
end
```

`inner_contract_validations` keeps stripping the shared options via `validator_entries`, so the tolerance does not travel into the forwarded contents. It does not need to: the standing-down happens one level up, in one place, rather than being re-expressed as flags on every forwarded entry.

`validate_each`'s own field-level nil-skip is **removed**:

```ruby
# delete — the pair is positional now, so this line would let a nil-tolerant POSITION
# excuse a nil FIELD, which is the conflation this ticket exists to end.
return if value.nil? && (options[:allow_nil] || options[:allow_blank])
```

PRO-3193 measured this line as not load-bearing — the suite is green without it, since both branches `return unless value.is_a?(…)` and no-op on a nil field regardless.

One residue is accepted, and it is the only cost of reusing AM's key names. `EachValidator#validate` skips `validate_each` outright when the attribute is nil-or-blank and the options say so, and that is AM's code, not removable. So a positionally tolerant bag also suppresses the whole `of:` check for a nil or blank *field*. Measured unobservable at every position: a nil field is already rejected by the container's mandatory `type: Array`/`Hash` (or, on a tolerant field, is legal anyway), a blank container has no positions to iterate, and a nested bag's "field" is the outer position's value, whose own class check reports first. Stated here because it is a real conflation that happens to have no reachable consequence, rather than one that was designed away.

### Declaration guards

`_reject_positional_bag_validators!` currently passes `tolerance: {}` with a comment citing this ticket — "a bag's `allow_nil:`/`allow_blank:` do not govern its position (PRO-3225), so honouring them here would stand the guard down for a rescue that never happens". After this change they do govern it, so the bag's own pair is passed instead, and the comment is rewritten. Both guards then read the bag exactly as they read a field.

The field-level refusal of tolerance beside an explicit `presence:` extends to a bag position for the same reason it exists at a field: the tolerance is applied to every check at that position, so the presence check could never fail.

```ruby
of: { klass: String, presence: true, allow_blank: true }
# ArgumentError — dead machinery, refused at declaration
```

### Emission

`bag_nullable?` already asks `Base.nil_accepted?` of the bag, but through `bag_value_constraints`, which strips the shared options — so the bag's tolerance never reaches it. The strip is removed for the tolerance pair specifically, and the pair is passed as the declaration tier into the same helpers a field's emission uses. Reusing the field's helpers is the requirement, not a convenience: the field-level behaviour is precise and non-obvious, and a second implementation would drift from it.

Measured field-level precedent, which the bag must mirror exactly:

| declaration | emits |
| -- | -- |
| `type: String, length: { minimum: 2 }` | `{type: "string", minLength: 2}` |
| `… , optional: true` (⇒ `allow_blank`) | `{type: ["string","null"]}` — floor **dropped**, since `""` passes |
| `… , allow_nil: true` | `{type: ["string","null"], minLength: 2}` — floor **kept**, since `""` still fails |
| `type: String, format: /…/, optional: true` | `{type: ["string","null"], pattern: "…"}` |

So `of: { klass: String, length: { minimum: 2 }, allow_blank: true }` must emit `items: {type: ["string","null"]}` with no `minLength`, and the `allow_nil:` spelling must keep it.

The last row is a known divergence in the strict direction — `allow_blank` lets `""` through at runtime while the emitted `pattern` rejects it — and is **not** in scope here. It is a field-level property this work inherits by reusing the field's helpers, which is the correct outcome: the bag agreeing with the field is the invariant, and moving the field is PRO-3240's business.

## The failure grid

Positions: **F** the field's own value (the control, unchanged), **E** an Array's element bag, **V** a map's `values:` axis, **K** a map's `keys:` axis. A nested bag at depth ≥ 2 is an E, V or K by construction.

| declaration | F | E | V | K |
| -- | -- | -- | -- | -- |
| `optional: true` | canonicalized to `allow_blank` (today) | canonicalized to `allow_blank` | same | same |
| `allow_nil: true` | tolerance (today) | position tolerates `nil` only | same | same |
| `allow_blank: true` | tolerance (today) | position tolerates `nil` and blank | same | same |
| tolerance + `presence: true` | refused (today) | refused (new) | refused | refused |
| tolerance + `length: { minimum: n }` | legal; floor dropped for `allow_blank`, kept for `allow_nil` | same, via the field's helpers | same | same |
| `if:` / `unless:` | gate (today) | gates the field's `of:` entry — kept | refused (today, kept) | refused (today, kept) |
| `on:` | refused (today) | refused (today) | refused (today) | refused (today) |
| `except_on:` | **declares cleanly, inert** | **declares cleanly, inert** | refused (today) | refused (today) |
| `strict:` | refused (today) | refused (today) | refused (today) | refused (today) |

Emission per position: E → `items`, V → `additionalProperties`, K → `propertyNames`, each nullability-reconciled by the existing `reconcile_contents_nullability`.

## `if:` / `unless:` / `strict:`, settled

The ticket asked for these to be decided alongside tolerance rather than separately. They are, by one rule: **a bag admits an option when the position actually reaches it.**

* `strict:` — refused at every position already (`_reject_inner_contract_strict!`), because axn has no strict-raising mode anywhere. No change.
* `on:` — refused at every position already (`_reject_validator_context_scope!` for a field's entries, `_reject_inner_contract_context_scope!` for a bag), because axn has no validation contexts. No change.
* `except_on:` — a hole this settlement closes. Measured: it declares cleanly at a field entry *and* in an element bag, and only the axis refuses it (it rides in `AXIS_INERT_OPTION_KEYS`). It is AM's other context option and axn has no contexts, so it is inert — but inert in the opposite direction to `on:`. AM installs it as `unless: -> { Array(options[:except_on]).include?(validation_context) }`, and axn calls `valid?` with no context, so `[:y].include?(nil)` is false and the entry **always** runs. The exclusion excludes nothing on any call. Refused at every position, structured as its own predicate/refusal pair rather than by widening `entry_context_scoped?` — the message has to name the opposite direction from `on:`'s "that check runs on no call at all", and a shared predicate feeding two messages is the drift these pairs exist to prevent. It mirrors `strict:` exactly: `Base.entry_declares_except_on?` beside `entry_declares_strict?`, `_reject_validator_except_on!` beside `_reject_strict_validation!` for a field's entries, `_reject_inner_contract_except_on!` beside `_reject_inner_contract_strict!` for a bag at any position.

  In scope because the ticket asked for the bag's shared options to be settled as one question, and this is one of them — measured as part of that sweep rather than found separately. It is also the only shared option whose field-level treatment this work changes, which is why it is called out rather than folded in silently.
* `if:` / `unless:` at an **element** — kept. axn never writes them into a bag, and gating the `of:` entry is exactly what an entry-level `if:` means for every other validator (`format: { with: /x/, if: :flag }`). Refusing them would remove a real capability: gating the element check *without* gating the sibling `type:`.
* `if:` / `unless:` at an **axis** — kept refused. Nothing reads a gate there. Measured: `of: { values: { klass: Integer, if: -> { false } } }` still rejects `{a: "x"}`.
* `allow_nil:` / `allow_blank:` / `optional:` — the subject of this spec: admitted at every position, meaning the position.

The element/axis asymmetry the ticket was uneasy about survives, but it stops being an artifact of the push. It is now a consequence of the rule, and it applies to a strictly smaller set of keys than before.

## Breaking-change assessment

Measured against the current declaration behaviour, not assumed.

**Not breaking.**

* Tolerance keys in a bag gaining their positional meaning. A no-op today, at every position, measured across the matrix above.
* `optional:` in a bag. Currently refused outright — `of: does not support optional:` — so admitting it is purely additive.
* Lifting the axis refusal of `allow_nil:`/`allow_blank:`. Additive; the declaration raises today.
* `config.validations` moving the pair from every entry to the top level. Visible to a downstream gem that reads the bag, which is why it was measured rather than argued: `optional?`, requiredness, nullability and every emitted schema are unchanged, and `spec/downstream_contracts/axn_mcp_interface_spec.rb` passes untouched. A consumer doing its own per-entry tolerance read would see the change, so the downstream-contract specs are the gate on this, not the unit specs.

**Breaking, at declaration time only — no runtime behaviour changes silently.**

* `of: { …, presence: true, allow_blank: true }` and its `allow_nil:`/`optional:` spellings. Measured: this declares cleanly today and enforces the positional `presence:` while ignoring the tolerance. Once the tolerance is real the two contradict, so it is refused — the same rule, and the same reasoning, as the field-level refusal that already exists. The inline raise in `_parse_field_validations` has to be extracted to be reachable from the bag path.
* `except_on:` at a field entry and in an element bag. Measured inert in both places (the entry always runs), so nothing can depend on it, but the declaration raises where it did not.

Both are declaration-time raises on dead or contradictory machinery, which is the disposal PRO-3219 and PRO-3220 already established for this class, and which the pre-alpha tombstone convention (PRO-2927) permits without a deprecation cycle. Calibrate the CHANGELOG `[BREAKING]` marker against the last released tag rather than against `main`.

**Behaviour change, not a refusal.**

* The two confirmation-companion messages, as described in Part A. `"can't be blank"` becomes `"is not a String"` for a typed base carrying `allow_nil:`/`optional:`; requiredness is still enforced, and an untyped base is unchanged.

## Retractions

Five statements say this cannot be done and must be withdrawn as it lands.

* `docs/reference/class.md:106` — "A bag's `allow_nil:`/`allow_blank:` govern **the whole field**, not the position … There is currently no per-element spelling". Replaced with the three spellings and the named-member parallel.
* `CHANGELOG.md:15` (the PRO-3193 entry) — the paragraph splitting both halves out as PRO-3225. Amended to point at this work.
* `lib/axn/core/contract.rb:2891` — the `tolerance: {}` comment. Rewritten as above.
* `spec/axn/core/validations/of_bag_value_validators_spec.rb:353` — the same claim in a spec comment.
* `lib/axn/core/validation/validators/of_validator.rb` — `inner_contract_validations`' comment ("Whether a bag's `allow_nil:`/`allow_blank:` govern the POSITION is a separate question, and not one this method may answer by accident") and `validate_position`'s ("`allow_blank` governs whether the whole field may be absent … not whether individual elements or entries may be blank").

## Not in scope

* The `allow_blank` + `format:`/`pattern:` strict-direction divergence — a field-level property, PRO-3240.
* `coerce:` at a bag position — a transform, not a constraint; needs to settle against PRO-2903's read-path doctrine first (own ticket, per PRO-3193).
* `uniqueness:` at any position — PRO-3219 owns it.
