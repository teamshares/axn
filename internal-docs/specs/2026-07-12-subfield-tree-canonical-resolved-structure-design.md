# Design spike: SubfieldTree as the canonical resolved-subfield structure (PRO-2883)

Linear: https://linear.app/teamshares/issue/PRO-2883/axn-design-spike-subfieldtree-as-the-canonical-resolved-subfield

Spike question: should `Axn::Reflection::SubfieldTree` be promoted from a reflection/declaration-analysis artifact to **the** canonical resolved-subfield structure consumed by declaration + reflection + **runtime**, cached per class — and if so, how should the caching work?

**Verdict: yes, promote it — via a per-class identity-keyed cache plus a per-config resolved index, adopted by the runtime (approach B below), landing as one combined PR whose commits stay behavior-preserving until the capability-unlock commits at the end.** The caching decision PRO-2877 deferred turns out to have a clean answer that avoids the PRO-2856 nil-memoization footgun entirely, and the same structural move ("a top-level field is a depth-0 node") lets the change also collapse the duplicated top-level/subfield contract machinery.

This design builds on PRO-2877 (PR #153) as merged: two contradiction families raise at declaration (the dotted-name `model:` and model-batch-id cases), the stranding families are handled by `Schema.derive_annotations`' single bottom-up `{required, nullable}` pass, `_expects_subfields` validates-before-commit with two-pass reader generation, and the tree retains its carried-shape-member drop analysis.

## Current state (what the spike found)

Three consumer groups, three different relationships to the tree:

- **Declaration** (`ContractForSubfields._expects_subfields`, post-#153): builds a *candidate* tree per declaration call to run `SubfieldContradictions.detect` before committing configs. These builds are inherently throwaway — they include not-yet-committed configs — so they can share the builder but not a cache instance.
- **Reflection** (`SchemaReflection` → `Schema.build_input` + `Schema.dropped_deep_subfields`): builds the tree **twice per `input_schema` call** (once for emission, once for the dropped-subfield warning), fresh every time.
- **Runtime** (`Executor`, per `.call`): never touches the tree. Five flat passes over `subfield_configs` — `apply_inbound_preprocessing_for_subfields!`, `apply_defaults_for_subfields!`, `validate_subfields_contract!`, the subfield half of `validate_model_consistency!`, and sensitive-field resolution (`Contract._resolve_sensitive_fields` / `FacadeInspector`) — each re-resolving its parent ad hoc via `ContractForSubfields.resolve_parent` (root reader `public_send` + raw `Extract` digs) or `_wire_parent_key` + `provided_data`.

The runtime's write-back machinery is structurally hardwired to a top-level parent, and that hardwiring is exactly what blocks the capability set:

- `Executor#_parent_config` looks the parent up **only** among `internal_field_configs` by wire key, so `_materialize_object_parent!`'s object-shaped gate can't be evaluated for a nested parent.
- `update_subfield_value` writes into `provided_data[parent_field]` directly — there is no notion of an ancestor chain, so a nested parent has no write path and shared intermediate parents would be re-materialized per config (the race the ticket calls out).
- Consequently declaration rejects `default:`/`preprocess:`/`sensitive:` on any nested parent (`contract_for_subfields.rb`, the `nested_parent` guard) and `coerce:` on all subfields.

Hot-path cost, measured (3 top-level fields, 8 subfields incl. dotted paths, Ruby 3.2): `SubfieldTree.build` ≈ 22μs; a full `.call` of the same class ≈ 630μs. So building per `.call` uncached would cost ~3–4%; cached per class it rounds to zero. `input_schema` ≈ 130μs today, paying the double build.

## The caching decision

**Cache the built tree in a single class-level ivar, keyed by the identity of the config arrays it was built from; validity is decided by key comparison, never by value presence.**

```ruby
# Sketch — lives alongside ContractForSubfields' ClassMethods
def _resolved_subfields
  fields = internal_field_configs
  subfields = subfield_configs
  cached = @_axn_resolved_subfields
  return cached.value if cached&.fields.equal?(fields) && cached.subfields.equal?(subfields)

  built = Axn::Reflection::ResolvedSubfields.build(fields, subfields) # tree + annotations + per-config index, deep-frozen
  @_axn_resolved_subfields = CacheEntry.new(fields:, subfields:, value: built)
  built
end
```

Why this shape works — and why it dodges every footgun the ticket flags:

- **Copy-on-write makes identity a perfect cache key.** Both stores are `class_attribute`s mutated exclusively via `self.internal_field_configs += ...` / `self.subfield_configs += ...` (the `<<`-mutation hazard is already documented and avoided at both sites), so *any* declaration mints new array objects. Two `equal?` checks per read decide validity — O(1), no content hashing.
- **No explicit invalidation, anywhere.** There is nothing to call from `expects`/`_expects_subfields`, so a future third mutation site (or an extension gem appending configs) is auto-covered instead of silently staling the cache. This closes the whole "forgot an invalidation site" class, not just today's two instances.
- **No nil-memoization footgun** (the PRO-2856 deferral): validity is the key comparison, not truthiness of the cached value. A class with zero subfields caches its (valid, mostly-empty) result exactly like any other — no `||=` re-derivation per read, no sentinel needed.
- **Copy-on-write subclass inheritance falls out for free.** A subclass that declares nothing new reads the superclass's arrays through the `class_attribute` reader; its own ivar is unset, so it builds an identical tree once and caches it per class. A subclass that declares more gets new arrays and a fresh build. (Optional micro-optimization, not required for correctness: before building, walk to the nearest ancestor whose `@_axn_resolved_subfields` key `equal?`s the same arrays and share its value. Deferred — the duplicate build is ~22μs once per class.)
- **Thread-safe by construction.** The entry is assembled fully (and deep-frozen) before the single ivar write publishes it; a first-call race between threads builds the same value twice and last-write-wins. No lock needed.
- **Deep-freeze at build time.** The builder mutates `Node#children` hashes while constructing; a post-build recursive freeze makes the published structure immutable, which both hardens the hot path and turns any accidental runtime mutation into an immediate `FrozenError`.

Rejected alternatives:

- `||=` memoize + explicit invalidation calls in the two declaration sites: nil-footgun avoidable with care, but every future mutation site is a silent staleness bug. Rejected.
- Build-on-write (declaration eagerly rebuilds the cache): declaration's contradiction builds are pre-commit candidates and can't be the cache; top-level `expects` doesn't build today and would have to start; classes that are declared but never called/reflected pay eagerly. Rejected in favor of lazy build-on-read.
- Content-equality key: strictly worse than identity given copy-on-write guarantees; O(n) compares per read for no added safety. Rejected.
- No class cache (build per `.call`): simplest, and only ~3–4% — but it's pure waste on every call, the ticket's capability set needs the per-config index anyway, and reflection wants the cache too. Rejected.

## What "canonical" means structurally: the per-config resolved index

The tree alone is the wrong lookup shape for the runtime, whose passes iterate `subfield_configs` in declaration order (error aggregation order is observable behavior). The promotion therefore adds a third artifact to the built result, recorded during the existing build loop (the `hops` are already computed per config — today they only feed the drop pass and subfield-anchor bookkeeping, then get discarded):

```ruby
Result = Data.define(:roots, :dropped, :annotations, :index)
# index: config => ResolvedPath, compare_by_identity
ResolvedPath = Data.define(
  :node,          # the config's leaf Node
  :root_reader,   # reader_as symbol of the top-level root (what resolve_parent public_sends)
  :wire_path,     # [root wire key, *segments] — the provided_data write path
  :ancestors,     # [[Node, wire segment], ...] outermost-first — the hops, for materialization gating
)
```

`annotations` is `Schema.derive_annotations`' identity-keyed `{Node => NodeAnnotation}` map, computed once at build and cached with the tree (reflection reuses it; runtime doesn't need it initially, but stranded-path error messages will want `required`).

This keeps one builder as the single source of truth (per the mirror-layers rule: consumers reuse, never re-derive): declaration's contradiction detection, reflection's emission/annotations/drop pass, and the runtime's resolution recipes all come out of the same `build`.

## Runtime adoption

The five runtime passes keep their declaration-order iteration over `subfield_configs`; each looks up its `ResolvedPath` from the cached index instead of re-splitting `on:` strings and re-resolving aliases per pass.

**Read path (validation, model consistency).** Parent values get a per-call memo (living on the Executor instance for the duration of the inbound phase, keyed by resolution-recipe prefix — see the wrinkle below): resolve the root once via its reader, each deeper segment once via `Extract`, and every config sharing an ancestor chain reuses the resolved values. Today `resolve_parent` re-digs the full chain per config; the memo is a strict reduction of repeated work with identical semantics.

One wrinkle the canonicalization surfaces (discovered during the spike): **the same wire path can carry two resolution semantics depending on spelling.** `expects :c, on: :b` (where `:b` is a `model:` subfield) resolves the parent via `public_send(:b)` — the *resolved model record* — while `expects :c, on: "a.b"` resolves via `public_send(:a)` + raw dig of `:b` — the *raw hash value*. The tree puts both configs on the same node. The index therefore preserves each config's own resolution recipe (`root_reader` + raw segments exactly as `resolve_parent` behaves today) rather than unifying to per-node resolution; the per-call memo keys on the recipe prefix (root reader + segments so far), so identical spellings share work and divergent spellings stay divergent. Unifying the two spellings is a semantic change to consider separately, not smuggled into this refactor.

**Write path (defaults, preprocess, future coercion).** Replace the three hardwired helpers (`_parent_config`, `_materialize_object_parent!`, `update_subfield_value`) with chain-aware equivalents driven by `ResolvedPath`:

- Materialization walks `ancestors` outermost-first and synthesizes each missing intermediate `{}` **only if every node to be synthesized is object-shaped** — evaluated per node from its own configs via the existing `Schema.object_shaped?` (an implicit node, having no configs, is unconditionally object-shaped). This is the same gate `_parent_object_shaped?` implements for the top-level case and the same predicate PRO-2877's defaulted-node shield reuses, now applicable at every depth because the tree knows every ancestor's declared type — the thing `_parent_config`'s top-level-only lookup structurally couldn't.
- Because materialization is driven from the shared tree rather than per config, two defaults under the same intermediate parent materialize it once, top-down — eliminating the per-config race on shared intermediates that the ticket identifies as the hard part.
- Defaults stay in **declaration order** — the runtime-truth matrix showed the pre-order idea was NOT invisible today (interacting dotted-name defaults already resolve by declaration order: the first-declared default materializes, and a later ancestor default sees a present value and skips), so declaration order is the observable contract at every depth and nested defaults inherit it unchanged. Chain-shared materialization (each intermediate created once, in the tree) removed the coordination problem pre-order was meant to solve.
- PRO-2857 semantics are preserved and generalized: preprocess still never synthesizes ancestors (a nil chain means the subfield is absent and the write no-ops); defaults synthesize only fully-object-shaped chains.

**Sensitive filtering.** `FacadeInspector`/`_sensitive_field_keys` currently match `config.on` against top-level fields. With `wire_path` available, a nested `sensitive: true` subfield contributes its full dotted wire path (`ActiveSupport::ParameterFilter` accepts nested `a.b` keys), which is what lifts the `sensitive:` half of the declaration guard.

**Ambient context** stays on its current flat filter. Deep ambient nesting (PRO-2844/2845) becomes straightforwardly buildable — `_filter_to_declared` walking the ambient root's subtree — but stays out of scope here; the declaration-time rejections of deep ambient shapes remain.

## Approaches considered

**A. Full promotion — tree-order traversal everywhere.** All five passes become recursive tree walks; per-config iteration disappears. Cleanest end state, but it changes observable error-aggregation order (spec churn with no capability payoff), forces the on-spelling resolution unification immediately, and lands as one large high-risk change. The extra uniformity buys nothing approach B doesn't.

**B. Canonical cached tree + per-config resolved index (recommended).** The tree (with index + annotations) becomes the single cached resolved structure all three layers consume; runtime passes keep declaration-order iteration and per-config resolution recipes, gaining resolved chains, per-call memoization, and coordinated chain-aware write-backs. Behavior-preserving until the capability-unlock commits. Same end-capability set as A.

**C. Cache-only — reflection/declaration consume the cache; runtime untouched.** Cheapest now; fixes the double build in `input_schema`. But the entire unlocked set stays blocked, and each future runtime feature keeps hand-rolling ancestor resolution against a structure that already exists — per-config workarounds for nested write-back are precisely what races on shared intermediates. Rejected as the steady state; its content survives as the infra commits of approach B.

## Unifying the top-level and subfield contract machinery

The tree promotion is also the right moment to collapse the awkward parallel-class structure between top-level and subfield expectations — the tree's own framing ("a top-level field is a depth-0 node; a subfield is a deeper node") is what makes the unification principled rather than opportunistic. The spike confirmed nothing anywhere type-checks the two config classes (`is_a?`/`case` — zero hits); every consumer duck-types, and `Axn::Internal::FieldConfig` exists *precisely because* the two Data types are separate ("a field configuration object with a `validations` method"). The duplication map and what to do with each piece:

**Unify — config Data type.** `Contract::FieldConfig` and `ContractForSubfields::SubfieldConfig` differ only by `user_facing` (top-level-only today) vs `on` (subfield-only). Collapse to one `FieldConfig` with `on: nil` and `user_facing: false` defaults — and with kwarg parity (below), both fields are legitimately populated at either level. The two *stores* stay separate — `internal_field_configs` vs `subfield_configs` is a real structural distinction the tree builder, the identity-keyed cache, and many consumers rely on; merging the stores would churn everything for no gain. With one type, `Internal::FieldConfig`'s duck-typing helpers (`optional?`, `boolean?`, `subfield_default_applies?`) can become instance methods on the config itself.

**Unify — declaration parsing.** `_parse_field_configs` and `_parse_subfield_configs` are near-identical bodies (both call the already-shared `_parse_field_validations`, map to a config, conditionally define readers). One parametrized helper; the genuinely different parts — which readers get defined, the subfield `coerce:` rejection (until lifted) — stay as small injected differences. `expects` already branches to `_expects_subfields` at one entry point; that stays.

**Unify — one-off validator machinery.** `Validation::Fields` and `Validation::Subfields` both hand-build ActiveModel one-off classes with the same validator constants. Share the class-builder and errors plumbing; keep the two `read_attribute_for_validation` sources (context facade vs source-hash extract with model-reader fallback) as the per-flavor seam. Skipping empty validation sets in the shared builder fixes the incidental optional-only-subfield crash (below) by construction.

**Unify — executor write passes.** With `ResolvedPath`, a top-level field is the depth-0 case: `wire_path == [field]`, no ancestors, materialization gate vacuously true. `apply_inbound_preprocessing!`/`apply_defaults!`/`apply_inbound_coercion!` and their `_for_subfields!` twins collapse into single passes over both stores' resolved paths.

**Keep separate.** Reader *bodies* genuinely differ (facade delegation vs memoized parent-extract) — they share companion-reader plumbing (`_define_model_id_reader_from`, boolean predicates) already; don't force the rest. Ambient filtering stays as is.

## Kwarg parity: subfields support the same declaration surface as top-level fields

The unification's user-visible goal: `expects ..., on:` accepts the same kwargs with the same semantics as top-level `expects`. Full divergence inventory as of today, and the disposition of each:

| Divergence today | Disposition |
| --- | --- |
| `user_facing:` rejected with `on:`, and rejected on a parent that has subfields | **Support** — the settling generalization below |
| `coerce:` rejected on subfields | **Support** — coercion pass walks coerce-flagged nodes via the index (hook for PRO-2884's auto-extension) |
| `default:`/`preprocess:`/`sensitive:` rejected for a *nested* parent (depth-1 works) | **Support** — chain-aware write-backs + wire-path sensitive filtering |
| Shape `do…end` block rejected with `on:` (raw `shape:` kwarg already passes through and validates) | **Support** — reuse `_build_shape`; pure declaration sugar, no new runtime |
| Falsy subfield defaults never apply (`subfield_default_applies?` gates on truthiness); top-level applies on key-absence/nil and honors `default: false` | **Align to top-level semantics** — `default: false` on a boolean subfield becomes meaningful. Behavior change for existing contracts; schema reflection's `usable_default?`/applied-default predicates and PRO-2877's contradiction detector (which counts "applied" defaults) key off the old rule and must co-update in the same commit |
| Symbol-referenced validation args (`inclusion: { in: :method_name }`) work top-level via `Fields#method_missing` → action delegation; `Subfields` has no delegation | **Align** — add the same delegation to the shared validator builder |
| Empty validation set tolerated top-level, crashes subfields on every `.call` | **Align** — fixed by construction in the shared builder (see incidental finding) |
| `readers: false` is subfield-only (top-level rejects it) | **Remove the option entirely.** Downstream grep (2026-07-13) found zero uses of the `readers:` kwarg across all five consumers: os-app, axn-mcp, axn-ruby_llm, data_shifter, and slack_sender. Nothing internal uses it — every `lib/` reference is guard machinery defending against it: `_generated_subfield_reader_names` (and its copy-on-write bookkeeping) exists *solely* for the readerless-parent guard, plus the `as:`/`prefix:` incompatibility guard and the `_validate_reader_names!` skip. Its documented use case (duplicate sub-keys across parents) is served strictly better by `as:`/`prefix:` (rename instead of suppress), and it harbors an unconsidered edge: a `model:` subfield with `readers: false` validates the raw hash through `ModelValidator` instead of the resolved record (the reader fallback in `Subfields#read_attribute_for_validation`). Removal deletes the kwarg, the class_attribute, three guards, and a docs section — and this parity divergence with it |
| `user_facing:` + shape block rejected (nested member checks are dev-facing) | **Keep, symmetrically** — same rejection at both levels |
| Ambient subfields reject `default:`/`preprocess:` and all deep-ambient shapes | **Keep** — the ambient parent resolves per-invocation, not from `provided_data` (PRO-2844/2845 territory). Additionally reject `user_facing:` on ambient subfields: ambient values are framework-supplied, not caller input, so there is no user to face |

### Generalizing `user_facing:` to subfields

The current `_validate_inbound!` dominance dance *depends* on the invariant "subfields and model consistency are always dev-facing," and the parent-with-subfields rejection exists to guarantee that a failing user-facing field never has dependent subfield checks hanging off it. Supporting `user_facing:` on subfields (and on parents that have subfields) replaces that invariant with two generalized rules:

- **Classification follows the config, at any depth.** Every violation source — top-level field, subfield — classifies by its own config's `user_facing`; model-consistency mismatches stay structurally dev-facing. The settling rule is unchanged in spirit: any dev-facing violation dominates and raises unreclassified; only when *every* violation lands on a user-facing config does the failure compose into a user-facing message (`_user_facing_configs`/`_user_facing_message` generalize to draw from both stores, with field-scoped errors per config as today). The staged structure survives: a dev-facing top-level failure still raises immediately without consulting later checks.
- **Causal suppression via the ancestor chain.** When a parent fails its own validation, its subtree's checks are noise — a nil/invalid parent strands every descendant (PRO-2857), and letting a stranded required subfield's dev-facing failure dominate would page over the parent's user-facing message, which is exactly the mixed-settlement problem the old rejection avoided. The rule: skip subfield (and subfield model-consistency) checks whose `ResolvedPath` ancestors include a field that already failed — attribute the failure to the ancestor. This is tree-enabled: the flat config list can't see the ancestor chain; the index makes the suppression a lookup. It also subsumes today's behavior (dev-facing top-level failure raises before subfield checks run) as the degenerate case.

This is the one piece of the parity work that changes `_validate_inbound!`'s logic rather than just lifting a guard, so it deserves focused adversarial review and a spec matrix of its own: {parent user-facing, dev-facing, passing} × {subfield user-facing, dev-facing, passing} × {parent present, nil, absent}.

## Cost/benefit weigh-up (the ticket's ask)

Costs: one new cached artifact and its (footgun-free) validity rule; a substantial (but single, adversarially-reviewed) executor + declaration refactor; the deliberate semantic changes are confined to the capability commit (falsy-default alignment, the `user_facing` settling generalization).

Benefits: full kwarg parity between top-level and subfield declarations — nested `default:`/`preprocess:`/`sensitive:` (currently rejected, requested by the capability roadmap), subfield `coerce:` (follow-up B of PRO-2877, and the natural completion of PRO-2884's whole-action coercion, which today stops at top-level fields), `user_facing:` at any depth, shape blocks under `on:`; deep ambient nesting (PRO-2844/2845) unblocked; "which ancestor stranded this path" runtime errors; `input_schema` stops double-building; per-call subfield validation stops re-digging shared parent chains. The runtime hot-path cost question dissolves under the cache (~0 marginal; the per-node memo is a net reduction).

The weigh-up favors promotion clearly — the capability set is blocked on exactly the structure the tree already encodes, and the caching decision has a low-risk answer.

## Sequencing (single combined change)

This lands as **one PR** (adversarially reviewed by Codex rather than a human, and other sessions are in flight — splitting buys review-bandwidth we don't need at coordination cost we'd pay). It depends on PR #153 (PRO-2877) merging first — the design targets the post-#153 tree, and both changes rewrite `contract_for_subfields.rb`/`schema.rb`. Internal commit ordering still matters for bisectability and for keeping the behavior-preserving refactor separable from the capability unlock in review:

1. **Config/machinery unification (behavior-preserving):** one `FieldConfig` type, shared parsing helper, shared one-off validator builder (fixing the optional-only-subfield crash, with specs), `Internal::FieldConfig` helpers folded into the config type.
2. **Infra (behavior-preserving):** builder `Result` gains `index` + `annotations`; deep-freeze; identity-keyed per-class cache; `input_schema`/`dropped_deep_subfields`/`build_input` consume it (single build). Declaration keeps building candidate trees pre-commit.
3. **Runtime adoption (behavior-preserving):** read path resolves via the index with the per-call memo (per-config recipes preserved); write path replaces `_parent_config`/`_materialize_object_parent!`/`update_subfield_value` with chain-aware equivalents. Defaults stay declaration-ordered (see above).
4. **Capability unlock (kwarg parity):** lift the `nested_parent` guard for `default:`/`preprocess:`/`sensitive:` (+ nested sensitive filtering), the subfield `coerce:` rejection (the hook for PRO-2884's "auto-extend to subfields later"), the shape-block-with-`on:` rejection, and both `user_facing:` rejections (with the generalized settling + causal suppression, and its {parent}×{subfield}×{presence} spec matrix); align falsy-default semantics (co-updating the schema predicates, which key off the shared `applied_default?`). Stranded-path diagnostics: a failing nested check whose intermediate ancestor is nil names the stranding hop on :base (once per chain; a nil top-level root adds nothing — self-evident). The one-level-down contradiction-family review concluded: a required subfield with a default under an absent non-object intermediate is a schema/runtime divergence corner of the same accepted class as the existing top-level default divergence; the runtime errs dev-facing-safe (skipped default → validation error), never silently.

Before the runtime refactor lands, capture a runtime-truth spec matrix for the write-back edge cases (nil parents, non-object parents, shared intermediates, `default: false` at both levels) so the refactor is verified against observed behavior, not intended behavior.

PRO-2844/2845 (deep ambient) remains its own track, newly feasible on top of this.

## Out of scope

- Outbound subfields: `exposes` has no `on:` at all (no subfield concept on the output side), so kwarg parity here is inbound-only. Shape blocks remain the outbound nesting mechanism.
- Deep ambient nesting (PRO-2844/2845).
- Moving reader generation onto the tree (readers stay per-config; they're declaration-time and order-sensitive).
- Ractor-shareability of the cache (freeze gets us most of the way; not a current requirement).

## Incidental finding (fixed by the unification)

A subfield declared with only presence-tolerance and no actual validator — `expects :name, on: :user, optional: true` (or bare `allow_nil:`/`allow_blank:`) — raises `ArgumentError: You need to supply at least one validation` on **every** `.call`: `_parse_field_validations`' `allow_blank` branch `transform_values!`s an empty validations hash (a no-op), and `Subfields.validator_class_for` then calls `validates field` with zero validators. Top-level fields are immune (their else-branch injects `presence: true`, and the flat `Fields` runner tolerates the empty set). Pre-existing and independent of the tree promotion, but the shared one-off validator builder from the machinery unification fixes it by construction (empty validation sets are skipped, matching top-level behavior); the change should include specs for the newly-valid optional-only subfield.
