# Reject an `on:` that names an ActiveModel validation context (PRO-3022)

Ticket: https://linear.app/teamshares/issue/PRO-3022

Axn has no validation contexts. `Validation::Fields` calls `validator.valid?` with no context, and ActiveModel's `validate` installs a gate of `!(Array(options[:on]) & Array(validation_context)).empty?` whenever `options.key?(:on)` — so with no context that intersection is always empty and the gated validator runs on no call at all. Every declaration site accepts such an `on:` today and then silently enforces nothing.

Two meanings of `on:` share the spelling and only one is in scope. **Declaration-level `on:` on `expects`** (`expects :zip, on: :address`) is axn's subfield parent and is untouched by all of this. In scope is `on:` wherever it lands in a bag ActiveModel reads as validator options — plus the two sites where an `on:` is accepted and then evaporates for a *different* reason, because they are the same defect for an author (see C2/C3).

## What was measured, not inferred

Every row below was probed against `main`. The runtime column is the observed outcome, not a reading of the code.

| Site | What `on:` binds to | Observed on `main` |
|---|---|---|
| a validator ENTRY's bag, any route (`type: { klass: String, on: :create }`) | AM validation context | accepted; the entry runs on no call — `v: 5` passes a `String` check |
| a raw `shape:` member's bag, top level (`{ presence: true, on: :create }`) | AM shared option, reaching `validates` verbatim | accepted; **every** validator in the bag goes dead — the member accepts `nil` |
| a block-form member (`field :x, presence: true, on: :create`) | absorbed as `_parse_field_configs`' subfield-parent kwarg, then dropped by `ShapeConfig` | accepted; the option vanishes with no error (the validators do still run) |
| `exposes :v, on: :create` | absorbed as the subfield-parent kwarg; `exposes` has no subfields | accepted; stored as `config.on` on an outbound config, read by nothing |

Nested `on:` reproduces identically via top-level `expects`, `exposes`, an `on:` subfield, a block-form shape member, a raw `shape:` member, and `Axn::Factory.build`.

One correction to the ticket's framing: with a plain `expects :v, type: { klass: String, on: :create }` an *omitted* key is still rejected. `_default_presence_applies?` does not consult the type entry, so the inferred `presence: true` is installed and fires. What goes dead is the declared check, not requiredness.

### Scope item 3, confirmed rather than assumed

All six ActiveModel shared options were exercised nested inside an entry. `if:`/`unless:` gate per call, `allow_nil:`/`allow_blank:` skip per value, `strict:` raises. Only `on:` is unconditionally inert. There is no `strict:`-style passthrough sweep to write, and this design adds none.

## The guard, and why it cannot be inverted

The check is `Validation::Base.entry_context_scoped?` — already THE definition of "is this entry scoped to a context", shared by the nil-skip push-down, the emptiness axis and schema reflection. Using it here rather than a second reading is what keeps the guard and the predicates from disagreeing about one declaration.

It derives from what the consumer emits rather than predicting it: AM installs the context gate on `options.key?(:on)` after `defaults.merge(_parse_validates_options(options))`, and the predicate asks the key's presence at either tier. Normalization cannot change the answer — `_parse_validates_options` maps `TrueClass→{}`, `Range`/`Array`→`{in:}`, else→`{with:}`, none of which introduces an `:on` — and a non-Hash entry cannot carry one. So the raw entry is the exact form to read.

### One hardening it needs first

`entry_context_scoped?` tests `entry_opts.is_a?(Hash)`, and `is_a?` is an ordinary overridable method while ActiveModel's `_parse_validates_options` classifies with `case`/`when` (C-level `Module#===`, which never calls the object's `is_a?`). Verified: a `Hash` subclass denying `is_a?(Hash)` makes the predicate answer `false` while AM keeps the bag as options and installs the dead gate — the guard passes and the entry is still inert.

`ShapeGraph.detach_option_containers!` neutralizes that for almost every entry, since it runs ahead of the guard on **both** routes (`_parse_field_validations:1651`, `_symbol_keyed_member_validations:406`), classifies with `case value when ::Hash`, and replaces each Hash-valued entry with `copy_entries` — a plain `{}` axn owns. But it explicitly skips `:shape`, so *that* entry reaches the guard as the caller's own object, and `shape:` is a validator entry (see C1's last case). So the evasion is reachable.

`entry_context_scoped?` therefore classifies through `ShapeGraph.hash_or_nil` instead. Free, and the one-definition move: it makes the predicate agree with how AM classifies the same bag, and "a declaration guard a caller can invert is not a guard" applies with full force now that the fallback readers are going (C4). The detach ordering is still load-bearing for the *content* of what the guard reads and is stated there.

## C1 — a nested `on:` in a validator entry

A shared raiser, called from the two seams every declaration route funnels through, each supplying its own `where:` label. This mirrors `_reject_member_coerce!` / `_reject_model_transform!`, which likewise sit on their own route and share a message helper — rather than folding the check into `_canonicalize_validator_options!`, which is the seam for *expansions and the checks expansion makes possible*, and this check needs nothing expanded.

- **Field, subfield, `exposes`, block-form member, Factory** — `_parse_field_validations`, immediately after `_canonicalize_validator_options!` (`contract.rb:1669`). That position is ahead of every consumer of the bag: `_validate_allow_empty!`, `_reconcile_emptiness_axis!`, the tolerance push-down, and `_apply_nil_skip_to_non_type_validators!`. Ahead of the push-down also means the message quotes the author's own spelling rather than one with `{ allow_blank:, allow_nil: }` merged on.
- **Raw `shape:` member (including an object-backed one)** — `_symbol_keyed_member_validations`, beside `_reject_member_coerce!` (`shape_declaration.rb:413`). Every member reaches this walk whatever supplied it, since it reads `ShapeGraph.read(member, :validations)`.

The raiser scans `Base.validator_entries(validations)` — validator entries only — so a *bag-level* `:on` is out of its remit by construction and is reported by C2/C3 with their own reasons. Every offending entry is named in one message, not just the first.

Every validator is covered, axn's own included: `type:`, `of:`, `validate:`, `model:` and `shape:` are all validator entries rather than shared options, and none of the five reads `:on` for anything of its own — verified, so C1 rejects nothing legitimate.

`shape:` is the one case worth calling out. A raw `shape: { members:, container:, on: X }` is a validator entry carrying `:on`, so C1 catches it — and its behavior is the C1 kind: the stored node KEEPS the key — `snapshot_node` copies every entry — so the ShapeValidator itself goes inert and a member's own type check stops firing (`h: { x: 5 }` passes where the same declaration without `on:` fails). Rejecting it is still right (the author wrote something that does nothing), and the position matters: C1 sits at `:1669`, ahead of `_derive_raw_shape_container!` at `:1671`, so the key is still there to be seen.

Message, naming the field, the validator, the reason and the fix:

> `on:` inside `type:` on `["v"]` names an ActiveModel validation context, and axn validates with no context — so that check runs on no call and the declaration is left unenforced. Axn has no validation contexts: drop `on:`, or gate the check with `if:`/`unless:`, which axn does support.

A block-form member's label comes out as `["x"]` rather than `shape member \`payload.x\``, because it reaches this via `_parse_field_configs`. That is the existing behavior of every guard on that path (`_validate_allow_empty!` included) and is left alone rather than given a new label-threading mechanism.

## C2 — a bag-level `on:` on a shape member

A member's bag has neither meaning available: no validation context, and no subfield parent either. Rejected on both member routes, classified the way `SHAPE_MEMBER_READER_OPTIONS` already is — an option legitimate elsewhere, refused here for its own stated reason, rather than reported as an unrecognized key.

- New `SHAPE_MEMBER_CONTEXT_OPTIONS = %i[on].freeze` and `_raise_member_context_option!`.
- **Raw route** — a bucket in `_check_member_option_keys!`'s single classifying pass, ordered after the reader options and before "unknown".
- **Block route** — `_build_shape_member`, beside the existing two `_raise_member_*` calls, which run before `_parse_field_configs` absorbs the key.

`:on` stays in `KNOWN_MEMBER_VALIDATION_KEYS`. Removing it would make the raw route report "Unknown key(s)", which is false — the key is recognized, it just cannot mean anything on a member.

## C3 — `exposes :v, on: :create`

`exposes` has no `on:` kwarg, so the key falls through `**` into `_partition_field_options`, is accepted (`:on ∈ KNOWN_VALIDATION_KEYS`), and is then absorbed by `_parse_field_configs`' subfield-parent kwarg — landing as `config.on` on an outbound config, where nothing reads it. Rejected on key presence right after the partition, next to `_reject_dotted_field_name!(fields, on: nil, kind: "exposes")`, whose comment already records that `exposes` has no `on:`/subfields.

The message gives both halves, since an author reaching for it may have meant either: an exposure has no subfield parent to reach into, and axn has no validation contexts; to gate the outbound checks use `if:`/`unless:`.

## C4 — the inert-entry readers go, and a policy spec holds the impossibility

Seven reads in `lib/` become unreachable from any declaration once C1–C3 land: `Base.nil_tolerant_validation?:126`, `contract.rb:1791` (`_type_rejects_nil?`), `:1918` (`_entry_guaranteed_to_run?`), `:1937` (`_presence_emptiness_answer`), `:1957` (`_length_emptiness_answer`), and `schema.rb:874`/`:1349`. They are deleted, along with the branches' prose. `entry_context_scoped?` survives as the guard's single definition.

That is safe because the impossibility is **enumerable rather than hoped-for**. Exactly four places in `lib/` construct a stored `validations` bag, and every one funnels through a guarded seam:

| Constructor | Source of the bag |
|---|---|
| `contract.rb:1310` (`_parse_field_configs`) | `_parse_field_validations` — seam 1 |
| `contract.rb:1095` (`_build_shape_member`) | a config from seam 1 |
| `shape_declaration.rb:284` (the declaration walk) | `_symbol_keyed_member_validations` — seam 2 |
| `ambient_context.rb:173` | a literal `{}`, which can carry nothing |

A bypass would have to be a **fifth constructor of a stored bag** — a greppable, reviewed event, not a quiet drift.

So the fallback moves from `lib/` to a pin. A **policy spec asserts that set of four**, in the style of `error_policy_spec.rb` (which pins the exact untagged error classes) and `namespace_policy_spec.rb` (which pins the vacated namespace): add a fifth `FieldConfig.new`/`ShapeConfig.new` and the suite fails until whoever added it confirms it routes through a seam. A route enumeration alone would not do this job — it can only assert about sites that exist when it is written, so it protects against the guard being weakened or moved, not against a new constructor appearing.

What the pin is protecting has to be recorded **at** the pin, because the consequence of a bypass is worse than a schema mismatch and the next reader will not derive it:

- `_type_rejects_nil?` reading an inert type entry as authoritative hands `allow_nil: true` to *every other validator* on the field, so a `nil` passes with nothing left to reject it.
- `_reconcile_emptiness_axis!` defers `allow_empty: false` to a floor that never runs, so the flag is silently unenforced.

Both are runtime holes, not schema drift. That is the price of deleting the readers, and it is the argument for the pin rather than a reason to keep them: a bag that reaches those consumers is a bug either way, and the pin fails loudly at the commit that would cause it instead of quietly degrading at every call afterwards.

One consequence of the deletion, recorded rather than papered over: the retired examples were also the end-to-end proof that runtime and schema *agree* about an inert entry, and with the readers gone there is nothing left to assert that agreement about. It is not replaced by unit tests — it is genuinely dropped, because the state it described can no longer exist.

## Testing

### The 14 existing examples

All 14 arrived in one commit — `81c7ea11`, PRO-3016 — where `on:` is the *fixture*, not the subject: it is the only spelling that produces "a validator present in the bag that enforces nothing on any call", which is the state PRO-3016's predicates had to get right. A closed `if:` gate is not a substitute (reflection counts a gate as if it were open, static-maximal), and a falsy entry names nothing at all. They split three ways.

**Five table rows, dropped.** `schema_reflection_spec.rb:68` (a requiredness-parity table) and `:353–356` (a declaration-wide-tolerance-on-a-raw-member table, which is C2 in four spellings). Each table's own subject is untouched — the seven `allow_nil:`/`allow_blank:` rows carry the tolerance table by themselves — so the rows go and nothing is rewritten.

**One genuine rewrite.** `schema_reflection_spec.rb:870`, "emits no floor when the only other check is one no call runs", is about a *present-but-inert* `presence:` not counting as the other check. `presence: false` is a live fixture for that; verified identical on both axes — schema `{ type: "string" }`, and `v: ""` accepted.

**Eight convert into the C1/C2 regression examples.** `:703`/`:708` (the whole `describe "an entry scoped to a validation context, which never runs"`), and `nil_empty_axes_matrix_spec.rb:632`, `:644`, `:652`, `:659`, `:665`, `:960`. Rewriting these to "original intent" would either duplicate the `if: -> { false }` twin sitting immediately beside them (`616`, `640`, `968`) — misleadingly, since a twin exercises `entry_self_gated?` rather than `entry_context_scoped?`, and that predicate survives C4 — or is impossible: `:652`'s intent has no live fixture at all. Verified: `length: { minimum: 0 }` under `allow_empty: false` raises the emptiness conflict, and adding a closed `if:` gate *still* raises it, because `_length_emptiness_answer` never consults gates. Their assertions turn from "runtime and schema treat this as inert" into "this declaration raises, with this message."

The twins at `616`/`640`/`968` and the gated rows elsewhere are the coverage that has to *survive* C4 intact, since the gate predicates are the ones still reachable. Nothing in this change may touch them, and the inverse-mutation audit below is what confirms it.

While there: the gated contrast examples at `:711`/`:715` say "**still** emits the floor", reading as a contrast to a block that is leaving. Their prose is made to stand on its own.

### New examples

- **C1 across every route** — top-level `expects`, `exposes`, an `on:` subfield, a block-form member, a raw `shape:` member, an object-backed member, and `Axn::Factory.build`. This is the enumeration that substantiates the guard's coverage claim, so it is one focused spec rather than a row bolted onto an existing table.
- **Every spelling** — `on: :create`, `on: nil`, `on: false`, `on: []`, all rejected identically, since `Array(nil) & anything` is empty and AM gates on the key's presence whatever the value.
- **C1 on every validator** — the ActiveModel ones (`length:`, `presence:`, `inclusion:`, `numericality:`, `format:`) and axn's own (`type:`, `of:`, `validate:`, `model:`, `shape:`) — plus a declaration carrying two offending entries, which must name both.
- **The hardening** — a `Hash` subclass denying `is_a?(Hash)` as a `shape:` bag carrying `:on` is still rejected. This is the one entry the detach seam skips, so it is the example that fails if `entry_context_scoped?` regresses to `is_a?`.
- **The C4 policy spec** — the four stored-bag constructors, pinned, with what a bypass would cost written beside it.
- **C2 on both member routes**, with the reason distinguished from the reader-option and unknown-key messages.
- **C3**, asserting both halves of the reason.
- **Controls against over-rejection**, which is the recurring failure mode when a guard is tightened, so these are audited by inverse mutation (introduce an over-eager guard, confirm a control fails):
  - `expects :zip, on: :address` — the subfield parent, untouched.
  - `expects :zip, on: :address, type: { klass: String, if: :flag }` — a declaration-level `on:` beside a legitimately gated entry.
  - `expects :v, on: :ambient_context, ...` — the ambient parent.
  - a nested `if:`/`unless:`/`allow_nil:`/`allow_blank:`/`strict:`, each still accepted.
  - a bare `on:` on a *field* whose value is a declared reader, with every other shared option nested — nothing in C1 may fire.
  - the gate-predicate twins at `616`/`640`/`968` and the gated schema rows, unchanged and still passing — C4 deletes the context reads and must leave `entry_self_gated?`/`entry_effective_gate_keys` and everything reading them untouched.

Non-Rails `spec/` throughout; nothing here is Rails-adjacent (the `expects`/`exposes` grammar and ActiveModel's own option handling are loaded in both), so no `spec_rails` mirror is required.

## Docs and changelog

`docs/reference/class.md` already has "Conditional validation (`if:` / `unless:`)" at `:206`, which is exactly the fix the errors point at. A short paragraph there states that axn does not support ActiveModel **validation contexts** (`valid?(:create)`), that an `on:` inside a validator's options is refused at declaration for that reason, and that `if:`/`unless:` is the supported way to gate a check. It names the collision explicitly, since `on:` at declaration level on `expects` is axn's subfield parent and that section is not far from `:260`'s "Nested/Subfield expectations".

CHANGELOG under `## Unreleased`, which is genuinely the unreleased section here — `0.1.0-alpha.5.1` below it is tagged (`v0.1.0.pre.alpha.5.1`), so this is not the post-rename state where the top *version* heading would be the one to write under. Tagged `[BREAKING]`, since a declaration that defines cleanly today raises from now on: state the old behavior (accepted, then enforced nothing) against the new one, say loudly that a silent old behavior has become a raise, and name all four sites so an author can find the one they wrote. `## Unreleased` currently holds only `### Fixed`; this needs a sibling section in the prevailing style (`### Validation, coercion & schema` is the heading the released notes use for this area).
