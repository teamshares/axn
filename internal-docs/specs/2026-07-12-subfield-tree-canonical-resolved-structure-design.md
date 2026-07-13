# Design spike: SubfieldTree as the canonical resolved-subfield structure (PRO-2883)

Linear: https://linear.app/teamshares/issue/PRO-2883/axn-design-spike-subfieldtree-as-the-canonical-resolved-subfield

Spike question: should `Axn::Reflection::SubfieldTree` be promoted from a reflection/declaration-analysis artifact to **the** canonical resolved-subfield structure consumed by declaration + reflection + **runtime**, cached per class — and if so, how should the caching work?

**Verdict: yes, promote it — via a per-class identity-keyed cache plus a per-config resolved index, adopted by the runtime incrementally (approach B below).** The caching decision PRO-2877 deferred turns out to have a clean answer that avoids the PRO-2856 nil-memoization footgun entirely, and the runtime adoption can be sequenced so each PR is behavior-preserving until the capability-unlock PRs at the end.

This design assumes PRO-2877 (PR #153) has merged: the tree is contradiction-free by construction (four contradiction families raise at declaration), `SubfieldTree` is the simplified post-#153 version (no `blocking_ancestor?`; implicit ancestors never block), and `Schema.derive_annotations` computes `{required, nullable}` in one bottom-up pass.

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
- Defaults must apply parents-before-children (a parent's default may supply the hash its children's defaults then write into). Flat declaration-order iteration doesn't guarantee that once nesting is allowed; the defaults pass alone switches to a tree-order (pre-order) walk. This is invisible today (all default-carrying parents are top-level) and becomes load-bearing exactly when nested defaults are enabled.
- PRO-2857 semantics are preserved and generalized: preprocess still never synthesizes ancestors (a nil chain means the subfield is absent and the write no-ops); defaults synthesize only fully-object-shaped chains.

**Sensitive filtering.** `FacadeInspector`/`_sensitive_field_keys` currently match `config.on` against top-level fields. With `wire_path` available, a nested `sensitive: true` subfield contributes its full dotted wire path (`ActiveSupport::ParameterFilter` accepts nested `a.b` keys), which is what lifts the `sensitive:` half of the declaration guard.

**Ambient context** stays on its current flat filter. Deep ambient nesting (PRO-2844/2845) becomes straightforwardly buildable — `_filter_to_declared` walking the ambient root's subtree — but stays out of scope here; the declaration-time rejections of deep ambient shapes remain.

## Approaches considered

**A. Full promotion — tree-order traversal everywhere.** All five passes become recursive tree walks; per-config iteration disappears. Cleanest end state, but it changes observable error-aggregation order (spec churn with no capability payoff), forces the on-spelling resolution unification immediately, and lands as one large high-risk change. The extra uniformity buys nothing approach B doesn't.

**B. Canonical cached tree + per-config resolved index (recommended).** The tree (with index + annotations) becomes the single cached resolved structure all three layers consume; runtime passes keep declaration-order iteration and per-config resolution recipes, gaining resolved chains, per-call node memoization, and coordinated chain-aware write-backs. Only the defaults pass changes traversal order, exactly where semantics require it. Behavior-preserving until the capability PRs. Same end-capability set as A.

**C. Cache-only — reflection/declaration consume the cache; runtime untouched.** Cheapest now; fixes the double build in `input_schema`. But the entire unlocked set stays blocked, and each future runtime feature keeps hand-rolling ancestor resolution against a structure that already exists — per-config workarounds for nested write-back are precisely what races on shared intermediates. Rejected as the steady state; its content survives as PR-1 of approach B.

## Cost/benefit weigh-up (the ticket's ask)

Costs: one new cached artifact and its (footgun-free) validity rule; ~4 PRs of executor refactoring; two semantic edges to manage deliberately (defaults switching to pre-order; stranded-path error-message churn, isolated to its own PR).

Benefits: nested `default:`/`preprocess:`/`sensitive:` (currently rejected, requested by the capability roadmap); subfield `coerce:` subsumed (follow-up B of PRO-2877, and the natural completion of PRO-2884's whole-action coercion, which today stops at top-level fields); deep ambient nesting (PRO-2844/2845) unblocked; "which ancestor stranded this path" runtime errors; `input_schema` stops double-building; per-call subfield validation stops re-digging shared parent chains. The runtime hot-path cost question dissolves under the cache (~0 marginal; the per-node memo is a net reduction).

The weigh-up favors promotion clearly — the capability set is blocked on exactly the structure the tree already encodes, and the caching decision has a low-risk answer.

## Sequencing (proposed follow-on tickets)

1. **Infra (behavior-preserving):** extend the builder's `Result` with `index` + `annotations`; add deep-freeze; add the identity-keyed per-class cache; `input_schema`/`dropped_deep_subfields`/`build_input` consume it (single build). Declaration keeps building candidate trees pre-commit. Depends on PR #153 merging.
2. **Runtime read path (behavior-preserving):** `validate_subfields_contract!` + `validate_model_consistency!` resolve via the index with the per-call node memo, preserving per-config recipes. Optionally: stranded-path error messages (dev-facing message churn — its own commit/PR so it can be evaluated in isolation).
3. **Runtime write path:** chain-aware materialization/write-back replaces `_parent_config`/`_materialize_object_parent!`/`update_subfield_value`; defaults pass moves to pre-order. Still behavior-preserving (nested parents remain rejected at declaration). Then lift the `nested_parent` guard for `default:`/`preprocess:`/`sensitive:` + nested sensitive filtering — the capability PR, with its own contradiction-family review (a nested default under a nil-tolerant chain re-poses PRO-2877's family analysis one level down).
4. **Subfield `coerce:`:** lift the declaration rejection; the coercion pass walks declared coerce-flagged nodes via the index + write-back helper (also the hook for PRO-2884's "auto-extend to subfields later").

PRO-2844/2845 (deep ambient) remains its own track, newly feasible on top of 1–3.

## Out of scope

- Unifying the `on: :sub` vs `on: "parent.sub"` resolution-semantics divergence (flagged above; deserves its own decision).
- Deep ambient nesting (PRO-2844/2845).
- Moving reader generation onto the tree (readers stay per-config; they're declaration-time and order-sensitive).
- Ractor-shareability of the cache (freeze gets us most of the way; not a current requirement).

## Incidental finding (separate ticket)

A subfield declared with only presence-tolerance and no actual validator — `expects :name, on: :user, optional: true` (or bare `allow_nil:`/`allow_blank:`) — raises `ArgumentError: You need to supply at least one validation` on **every** `.call`: `_parse_field_validations`' `allow_blank` branch `transform_values!`s an empty validations hash (a no-op), and `Subfields.validator_class_for` then calls `validates field` with zero validators. Top-level fields are immune (their else-branch injects `presence: true`, and the flat `Fields` runner tolerates the empty set). Pre-existing, independent of this design; should be fixed at declaration or in `validator_class_for`.
