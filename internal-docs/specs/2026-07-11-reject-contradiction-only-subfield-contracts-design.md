# Reject Contradiction-Only Subfield Contracts at Declaration — Design

**Date:** 2026-07-11
**Ticket:** [PRO-2877](https://linear.app/teamshares/issue/PRO-2877/axn-reject-contradiction-only-subfield-contracts-at-declaration)
**Follow-up from:** PRO-2872 (PR #149, deep subfield reflection), PRO-2857 (nil subfield parent semantics)

## Context

PRO-2872's deep-subfield reflection derives schema requiredness/nullability from declaration composition. Several of the hairiest inference branches exist solely to make self-consistent sense of contracts that are author error: declarations whose flags can never all be honored at runtime. Per the repo's fail-at-declaration principle (AGENTS.md — "DSL misuse raises when the class is defined"; precedent: the ambient-nesting guards and PR #149's `readers: false` parent guard), these should raise clearly at declaration. Doing so lets `Axn::Reflection::Schema` replace each inference branch with an impossible-state assertion or delete it outright.

Runtime facts the design leans on:

- Declaration order guarantees ancestors precede descendants: an `on:` must name an already-declared reader (`contract_for_subfields.rb:60`), so subfield chains form a forest in declaration order and every cross-declaration contradiction *completes* at a subfield declaration. Hooking `_expects_subfields` is therefore sufficient and order-robust; no top-level `expects` hook is needed.
- `core/` already depends on `reflection/` (`contract.rb` uses `Reflection::Coercion`; `schema_reflection.rb` requires `axn/reflection`), so declaration guards may reuse `Reflection::SubfieldTree` without inverting layering.
- A nil/omitted parent yields every descendant absent (PRO-2857): resolving any field from a nil source returns nil, so a required deep leaf makes its whole ancestor chain effectively required and non-nullable at runtime.
- `SubfieldTree` is a reflection/declaration-analysis artifact only. The runtime `.call` path never touches it — subfield coercion/preprocessing/defaults/validation iterate the flat `subfield_configs` and resolve each parent ad hoc. So building the tree at declaration is off the hot path.
- Reflection is side-effect-free: it inspects declared configs, never runs user code (custom `validate:`/`model:`/`if:`/Proc defaults). This design preserves that.

## Goals

- Reject four families of contradiction-only subfield contracts at declaration with `ArgumentError`, each message naming the exact conflicting declarations (and, for family 4, the working alternative spelling).
- Reuse `SubfieldTree` (one resolution path) for the three families that need the resolved ancestor chain; keep the purely-local family a direct check.
- With the families illegal, replace the now-dead reflection inference branches with impossible-state assertions or deletions.
- Companion refactor: derive `{required, nullable}` per tree node in a single pass, so emission becomes a pure reader of those annotations — making the PR #149 rounds-5/8/9 "a dropped/blocked deep shape doesn't drop its runtime obligation" bug class impossible by construction.
- Preserve the surviving legal contracts unchanged (model parents, `type: Array`/mixed-union parents, representable deep chains).

## Non-goals

- Conditional requiredness ("if parent present, child required"). axn has no global conditional mechanism today (`if:`/`unless:` exist only on message handlers and step mounting; `optional:`/`allow_nil:` are static). Modeling it via one implicit subfield-only reading would be piecemeal; captured as Follow-up A.
- Rejecting deep subfields through a plain non-object *typed* parent (`type: Array`, mixed union) or a `model:` parent — those remain legal (mixed-union subfields read off the array branch; model parents resolve subfields off the record). Only the four enumerated families are rejected. Their `dropped_deep_subfields` warning stays for the type-blocked remainder.
- Caching the tree / promoting it to a runtime structure (Follow-up C).
- `coerce:` on subfields (Follow-up B), deep ambient nesting (PRO-2844/2845, in flight).

## Design

### The four families

Families 1–3 are cross-declaration and need the resolved ancestor chain; family 4 is local.

**Family 1 — nil-tolerant ancestor + required descendant.** `expects :payload, type: Hash, allow_nil: true` + `expects :id, on: "payload.meta"` (required). The `allow_nil:`/`optional:` is dead: a nil/omitted payload strands the required `id` (PRO-2857). Same for `optional: true` on an intermediate subfield whose subtree requires presence. Reject.
Message sketch: `":payload is declared nil-tolerant (allow_nil:/optional:) but :id (on payload.meta) is required — a nil/omitted :payload can never satisfy it; drop allow_nil:/optional: on :payload, or mark :id optional."`

**Family 2 — non-object shape member + colliding deep subfield.** `expects :payload, type: Hash do field :bar, type: String end` + `expects "bar.baz", on: :payload`. Runtime digging through a String does `String#[]` substring nonsense. Reject when a deep subfield's implicit hop collides with an ancestor `shape:` member that isn't `nestable_as_object?`.
Message sketch: `"subfield :baz (on payload, via bar.baz) nests under shape member `field :bar, type: String` on :payload, which is not an object — a nested subfield has nowhere to live; make :bar an object-shaped member or drop the nested subfield."`

**Family 3 — nil-tolerant `model:` parent + applied-default descendant.** `expects :company, model: ..., allow_nil: true` + a truthy-defaulted subfield (Proc included). Omission always fails at runtime: the default makes `apply_defaults_for_subfields!` materialize `{}` under the model's wire key *before* the default is evaluated, and `ModelValidator` rejects that `{}` — so the `allow_nil:` is dead weight and the failure is confusing. Reject when a nil-tolerant `model:` ancestor has any applied-default subfield in its subtree (`subfield_default_applies?`, Procs included).
Message sketch: `":company is a nil-tolerant model: but subfield :name (on company) carries a default — the default materializes `{}`, which the model validator rejects, so :company can never be omitted; drop allow_nil: on :company, or drop the subfield default."`

**Family 4 — dotted-name `model:` subfield.** `expects "org.company", on: :payload, model: ...`. A dotted name generates no reader (`_define_subfield_reader` returns early), so the id→record lookup never runs — the `<leaf>_id` token is unconsumable; only a Ruby caller passing the nested record validates. The identical capability works under `expects :company, on: "payload.org", model:` (full reader/id-resolution machinery). Reject the dotted-name spelling; point at the working one. Local check in `_parse_subfield_configs` (`validations[:model]` + dotted field name).
Message sketch: `"a dotted-name model: subfield (expects \"org.company\", on: :payload, model:) has no consumable id — the dotted name generates no reader, so the id→record lookup never runs; use the reader spelling instead: expects :company, on: \"payload.org\", model: ..."`

### Detection architecture

A new `Axn::Reflection::SubfieldContradictions` (module_function, sibling to `SubfieldTree`) takes the built tree + `field_configs` and returns `[{family:, offending:, ancestor:}]` structs describing each contradiction. It reuses the existing `Schema` predicates — `nil_accepted?`, `object_shaped?`, `nestable_as_object?`, `shape_members_at`, `subfield_default_applies?`, `dotted_model_config?` — so declaration (which raises) and reflection (which emits) share one notion of "contradictory."

`ContractForSubfields#_expects_subfields`, after appending its configs, builds the tree from configs-so-far (`SubfieldTree.build`) and runs the detector; the first contradiction found is formatted into an `ArgumentError` (naming both declarations, and for family 4 the working spelling) and raised. Family 4's local check stays in `_parse_subfield_configs` alongside the existing `coerce:` reject, since it needs no tree.

Building the tree per subfield declaration is O(configs) each, O(n²) across declarations — negligible at class-load time, off the hot path. The tree is **built fresh, not cached** (avoids the copy-on-write subclass + invalidation + PRO-2856 nil-memoization footguns); reflection continues to build fresh too. Only the *builder* is shared, not a cached instance.

### Reflection cleanup

With each family illegal, the corresponding inference branch is dead:

- **Family 1** collapses the flags-override reconciliation in `node_optional?`/`field_optional?`. A nil-tolerant node can no longer have a required subtree, so `nil_accepted?(c) && !subtree_requires_presence?(node)` simplifies to `nil_accepted?(c)`, and the parallel clause in `field_optional?` simplifies likewise. `required_child?` stays the single source of truth but no longer reconciles against an ancestor's nil-tolerance.
- **Family 2** deletes the shape-collision branch of `SubfieldTree.blocking_ancestor?` (the `node.children[key].implicit?` + non-nestable-member check) and `apply_implicit_node!`'s member-collision drop/merge coordination. The `node_configs_block_nesting?` (type/model) portion of `blocking_ancestor?` survives — those parents remain legal.
- **Family 3** deletes `subtree_has_applied_subfield_default?`'s **model-hazard use in `apply_model_id_requiredness!`** (the `{}`-materialization-under-nil-tolerant-model scan). The predicate itself survives — `required_child?` still uses it for the *shape-member synthesis* hazard on an object/Hash parent (`{}` synthesis triggering a required `shape:` member), which is a distinct, still-legal interaction, not a family-3 contradiction. So the Proc-counting rationale in the predicate's doc stays; only the model-id caller and its doc paragraph go.
- **Family 4** deletes the `dotted_model_config?` clause from `compute_dropped` and the dotted-model exclusions in `apply_children!`. `compute_dropped` shrinks to just the type-blocked (model/Array/mixed-union parent) drops. `dotted_model_config?` may be removable entirely if no caller remains; verify and delete if so.

Where a deleted branch guarded an invariant that *must* still hold (e.g. "a nil-tolerant node has no required subtree"), leave a lightweight impossible-state assertion (`raise "unreachable: …"`) rather than silently assuming it, so a future regression surfaces loudly rather than mis-emitting.

`dropped_deep_subfields` and the `input_schema` warning stay, narrowed to the type-blocked remainder; the warning message's dotted-model and shape-collision phrasing is trimmed.

### Companion refactor: single-pass annotation derivation

After the deletions shrink the derivation, add a single pass over the built `SubfieldTree` that annotates each node with `{required, nullable}` (and, for model routes, the `<field>_id`'s required/nullable) computed once. Emission (`build_input`, `apply_nested_subfields!`, `apply_children!`, `apply_implicit_node!`) becomes a pure reader of those annotations rather than recomputing requiredness/nullability at ~six sites. This makes the rounds-5/8/9 class of bug ("a dropped/blocked deep shape doesn't drop its runtime obligation, installed separately per site") impossible: obligation is computed at the node and read everywhere. Sequenced *after* the family deletions, per the ticket, so the derivation encodes the smaller post-rejection rule set.

## Testing

TDD, failing test first, both `spec/` (non-Rails) and `spec_rails/dummy_app/` where model behavior is involved (families 3 and 4 touch `model:`).

- **Per family:** a reproducing test that the contradictory declaration raises `ArgumentError` with a message naming both declarations (family 4: the working spelling). Cover each spelling that reaches the family (dotted `on:`, subfield-of-subfield, dotted name; top-level vs intermediate nil-tolerant ancestor for family 1).
- **Order independence:** where a family can be assembled in more than one declaration order, assert it raises regardless (declaration order is fixed by `on:`, but intermediate-vs-leaf ordering varies).
- **Surviving legal contracts:** model parents with subfields, `type: Array`/mixed-union parents with subfields, and representable deep chains still declare cleanly and reflect identically to pre-change (regression tests over `input_schema`).
- **Derivation parity:** reflection tests proving the single-pass annotation output matches runtime requiredness on the surviving legal contracts (the divergence documented in `schema.rb`'s header — stricter-than-runtime — is preserved).

## Compatibility

- `[BREAKING]` CHANGELOG entry per family under `## Unreleased`, each stating old-vs-new explicitly (contracts that previously loaded and partially functioned now raise at declaration) and the fix. Consumer upgrade is handled via the maintainer's already-open upgrade PRs, which pull this in on landing.
- No runtime behavior change for legal contracts; the change is purely additional declaration-time rejection plus reflection simplification.

## Follow-ups (captured, not in scope)

- **A — Global conditional requiredness:** `if:`/`unless:` on validations, or a dynamic `optional:`, applied uniformly to every field and reflected consistently. The deliberate home for the family-1 "conditional" interpretation.
- **B — `coerce:` on subfields:** mirror the existing `apply_inbound_preprocessing_for_subfields!`/`apply_defaults_for_subfields!` passes with an `apply_inbound_coercion_for_subfields!` pass; drop the declaration reject; reflect the wire type. Small, cheap, independent of the tree. Main design work is ordering (coerce→preprocess→defaults→validate) consistency.
- **C — SubfieldTree as canonical resolved-subfield structure (design spike):** promote the tree to a per-class cached structure consumed by declaration + reflection + *runtime*. Unlocks nested `default:`/`preprocess:`/`sensitive:` (blocked today because runtime write-back/materialization is top-level-parent-only — needs the resolved ancestor chain + coordinated top-down materialization), subsumes B, and feeds deep ambient (server_context for axn-mcp). Forces the caching/hot-path decision this ticket deliberately avoids; PRO-2877's trusted contradiction-free tree + single-pass derivation is the stepping stone to it (the builder is reused; caching is a wrapper).
