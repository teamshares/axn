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

`entry_context_scoped?` tests `entry_opts.is_a?(Hash)`, which a Hash subclass overriding `is_a?` could ordinarily invert — and "a declaration guard a caller can invert is not a guard". It cannot here, and the reason is ordering rather than the predicate: `ShapeGraph.detach_option_containers!` runs ahead of the guard on **both** routes (`_parse_field_validations:1651`, `_symbol_keyed_member_validations:406`), it classifies with `case value when ::Hash` (C-level `Module#===`, which does not call the object's `is_a?`), and it replaces each Hash-valued entry with `copy_entries` — a plain `{}` axn owns. So the guard is asked of axn's own Hash in every case. That ordering is load-bearing and is stated at the guard.

A lying subclass is not a divergence even in principle: AM's own `_parse_validates_options` classifies with `case`/`when` too, so the entry AM would treat as `{ with: <obj> }` is the one axn declines to read as context-scoped. The two agree.

## C1 — a nested `on:` in a validator entry

A shared raiser, called from the two seams every declaration route funnels through, each supplying its own `where:` label. This mirrors `_reject_member_coerce!` / `_reject_model_transform!`, which likewise sit on their own route and share a message helper — rather than folding the check into `_canonicalize_validator_options!`, which is the seam for *expansions and the checks expansion makes possible*, and this check needs nothing expanded.

- **Field, subfield, `exposes`, block-form member, Factory** — `_parse_field_validations`, immediately after `_canonicalize_validator_options!` (`contract.rb:1669`). That position is ahead of every consumer of the bag: `_validate_allow_empty!`, `_reconcile_emptiness_axis!`, the tolerance push-down, and `_apply_nil_skip_to_non_type_validators!`. Ahead of the push-down also means the message quotes the author's own spelling rather than one with `{ allow_blank:, allow_nil: }` merged on.
- **Raw `shape:` member (including an object-backed one)** — `_symbol_keyed_member_validations`, beside `_reject_member_coerce!` (`shape_declaration.rb:413`). Every member reaches this walk whatever supplied it, since it reads `ShapeGraph.read(member, :validations)`.

The raiser scans `Base.validator_entries(validations)` — validator entries only — so a *bag-level* `:on` is out of its remit by construction and is reported by C2/C3 with their own reasons. Every offending entry is named in one message, not just the first.

Message, naming the field, the validator, the reason and the fix:

> `on:` inside `type:` on `["v"]` names an ActiveModel validation context, and axn validates with no context — so that check runs on no call and the field is left unvalidated. Axn has no validation contexts: drop `on:`, or gate the check with `if:`/`unless:`, which axn does support.

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

## C4 — the inert-entry readers stay

Seven reads become unreachable from any declaration: `Base.nil_tolerant_validation?:126`, `contract.rb:1791` (`_type_rejects_nil?`), `:1918` (`_entry_guaranteed_to_run?`), `:1937` (`_presence_emptiness_answer`), `:1957` (`_length_emptiness_answer`), and `schema.rb:874`/`:1349`.

They stay, as defense-in-depth. The cost asymmetry decides it: keeping them costs seven one-line reads whose coverage is unit-level, while removing them means that any future route reaching a consumer without passing C1/C2 puts the schema back to advertising a constraint the runtime never applies — the PRO-3016 bug, in a layer whose bar is that a subtle bug here is a bug everywhere. The repo keeps cheap documented fallbacks of exactly this shape already (the `strict:` stand-down in `_apply_nil_skip_to_non_type_validators!`, justified by a case that "never raises regardless").

Their seven separate multi-paragraph justifications collapse to one canonical explanation at `entry_context_scoped?`, with each site pointing at it. Written in the present tense — a context-scoped entry is refused at declaration, and these reads keep a bag that arrives with one anyway from being misread — not as a history of what used to reach them.

Two things recorded honestly at that comment rather than papered over:

- These reads cannot be mutation-audited the way `AGENTS.md` asks. Removing one leaves the suite green, because nothing can construct the state through a declaration.
- The examples being retired also served as the end-to-end proof that runtime and schema *agree* about an inert entry. Unit tests on the two predicates assert each side separately and do not reproduce that agreement. That is a real reduction in what the suite proves, inherent to keeping the readers rather than to how the retarget is done.

## Testing

### The 14 existing examples

All 14 arrived in one commit — `81c7ea11`, PRO-3016 — where `on:` is the *fixture*, not the subject: it is the only spelling that produces "a validator present in the bag that enforces nothing on any call", which is the state PRO-3016's predicates had to get right. A closed `if:` gate is not a substitute (reflection counts a gate as if it were open, static-maximal), and a falsy entry names nothing at all. They split three ways.

**Five table rows, dropped.** `schema_reflection_spec.rb:68` (a requiredness-parity table) and `:353–356` (a declaration-wide-tolerance-on-a-raw-member table, which is C2 in four spellings). Each table's own subject is untouched — the seven `allow_nil:`/`allow_blank:` rows carry the tolerance table by themselves — so the rows go and nothing is rewritten.

**One genuine rewrite.** `schema_reflection_spec.rb:870`, "emits no floor when the only other check is one no call runs", is about a *present-but-inert* `presence:` not counting as the other check. `presence: false` is a live fixture for that; verified identical on both axes — schema `{ type: "string" }`, and `v: ""` accepted.

**Eight convert into the C1/C2 regression examples.** `:703`/`:708` (the whole `describe "an entry scoped to a validation context, which never runs"`), and `nil_empty_axes_matrix_spec.rb:632`, `:644`, `:652`, `:659`, `:665`, `:960`. Rewriting these to "original intent" would either duplicate the `if: -> { false }` twin sitting immediately beside them (`616`, `640`, `968`) — misleadingly, since a twin exercises `entry_self_gated?` rather than `entry_context_scoped?` — or is impossible: `:652`'s intent has no live fixture at all. Verified: `length: { minimum: 0 }` under `allow_empty: false` raises the emptiness conflict, and adding a closed `if:` gate *still* raises it, because `_length_emptiness_answer` never consults gates. Their assertions turn from "runtime and schema treat this as inert" into "this declaration raises, with this message."

While there: the gated contrast examples at `:711`/`:715` say "**still** emits the floor", reading as a contrast to a block that is leaving. Their prose is made to stand on its own.

### New examples

- **C1 across every route** — top-level `expects`, `exposes`, an `on:` subfield, a block-form member, a raw `shape:` member, an object-backed member, and `Axn::Factory.build`. This is the enumeration that substantiates the guard's coverage claim, so it is one focused spec rather than a row bolted onto an existing table.
- **Every spelling** — `on: :create`, `on: nil`, `on: false`, `on: []`, all rejected identically, since `Array(nil) & anything` is empty and AM gates on the key's presence whatever the value.
- **C1 on a validator other than `type:`** — `length:`, `presence:`, `inclusion:`, `numericality:`, `format:` — and a declaration carrying two offending entries, which must name both.
- **C2 on both member routes**, with the reason distinguished from the reader-option and unknown-key messages.
- **C3**, asserting both halves of the reason.
- **Controls against over-rejection**, which is the recurring failure mode when a guard is tightened, so these are audited by inverse mutation (introduce an over-eager guard, confirm a control fails):
  - `expects :zip, on: :address` — the subfield parent, untouched.
  - `expects :zip, on: :address, type: { klass: String, if: :flag }` — a declaration-level `on:` beside a legitimately gated entry.
  - `expects :v, on: :ambient_context, ...` — the ambient parent.
  - a nested `if:`/`unless:`/`allow_nil:`/`allow_blank:`/`strict:`, each still accepted.
  - a bare `on:` on a *field* whose value is a declared reader, with every other shared option nested — nothing in C1 may fire.
- **The readers' unit-level coverage** — `Base.nil_accepted?` and the schema layer asked directly of a bag carrying `:on`, plus each of the four `contract.rb` reads, since no declaration can reach them any more.

Non-Rails `spec/` throughout; nothing here is Rails-adjacent (the `expects`/`exposes` grammar and ActiveModel's own option handling are loaded in both), so no `spec_rails` mirror is required.

## Docs and changelog

`docs/reference/class.md` already has "Conditional validation (`if:` / `unless:`)" at `:206`, which is exactly the fix the errors point at. A short paragraph there states that axn does not support ActiveModel **validation contexts** (`valid?(:create)`), that an `on:` inside a validator's options is refused at declaration for that reason, and that `if:`/`unless:` is the supported way to gate a check. It names the collision explicitly, since `on:` at declaration level on `expects` is axn's subfield parent and that section is not far from `:260`'s "Nested/Subfield expectations".

CHANGELOG under `## Unreleased`, which is genuinely the unreleased section here — `0.1.0-alpha.5.1` below it is tagged (`v0.1.0.pre.alpha.5.1`), so this is not the post-rename state where the top *version* heading would be the one to write under. Tagged `[BREAKING]`, since a declaration that defines cleanly today raises from now on: state the old behavior (accepted, then enforced nothing) against the new one, say loudly that a silent old behavior has become a raise, and name all four sites so an author can find the one they wrote. `## Unreleased` currently holds only `### Fixed`; this needs a sibling section in the prevailing style (`### Validation, coercion & schema` is the heading the released notes use for this area).
