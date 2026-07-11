# Deep Subfield Nesting in Schema Reflection — Design

**Date:** 2026-07-10
**Ticket:** [PRO-2872](https://linear.app/teamshares/issue/PRO-2872/axn-represent-deep-subfield-nesting-in-schema-reflection)
**Follow-up from:** PRO-2842 (PR #141, reflection core), PRO-2871 (PR #147, dropped-deep-subfield warning), PRO-2857 (nil subfield parent semantics)

## Context

`Axn::Reflection::Schema.build_input` represents only single-level subfields: those whose `on:` names a top-level field's reader with a non-dotted field name. Three deeper forms validate at runtime but are omitted from the reflected input schema, currently surfaced only by the PRO-2871 one-time warning:

1. A dotted `on:` path — `expects :zip, on: "address.billing"`.
2. A subfield of a subfield — `expects :zip, on: :billing` where `:billing` is itself a subfield.
3. A dotted field name — `expects "bar.baz", on: :foo`.

This design represents all three in the emitted schema wherever the ancestor chain is structurally representable as JSON objects, and narrows the dropped-subfield warning to the genuinely unrepresentable remainder.

Runtime facts the design leans on:

- `ContractForSubfields.resolve_parent` reads the `on:` root via its *reader* (the `as:`/`prefix:` alias, `reader_as`) and digs remaining dotted segments with indifferent access (`FieldResolvers::Extract`). Schema properties, by contrast, are keyed by *wire key* (`config.field`), so reader→wire-key translation is required at each explicit hop.
- Declaration rejects `default:`/`preprocess:`/`sensitive:` on a nested PARENT (`contract_for_subfields.rb`): a `default:` is legal only when `on:` names a top-level reader. A dotted field NAME can still land a defaulted config on a deeper node (`expects "bar.baz", on: :foo, default: "zzz"` places a defaulted config at depth 2). The implementation honors such a default where it lands (`node_optional?`), but parent synthesis deliberately ignores it (`defaulted_child?` counts only depth-1 children) — the safe, stricter-than-runtime direction, so synthesis stays top-level-only. Deep/dotted ambient nesting is rejected at declaration outright.
- A nil/omitted parent yields every descendant as absent (PRO-2857): resolving any field from a nil source returns nil, so a required deep leaf makes its whole ancestor chain effectively required and non-nullable at runtime.
- `on:` must name an already-declared reader, so subfield chains form a forest (no cycles) in declaration order.

## Goals

- Represent deep subfields (all three forms, and their compositions) in `input_schema` as nested `properties`/`required`, composing with the existing `model:`/`of:`/`shape:`/union-parent handling.
- Preserve the requiredness/nullability derivation invariants documented at the top of `schema.rb`, extending them to arbitrary depth, and close the documented divergence where a required deep subfield under a nil-tolerant parent did not force the parent required.
- Keep reflection side-effect-free (never runs user code; identity-based membership tests only).
- Keep `dropped_deep_subfields` and the `input_schema` warning, narrowed to configs that remain structurally unrepresentable.

## Non-goals

- Shallow subfields on a non-object top-level parent (e.g. `type: Array` + `expects :length, on: :items`) keep today's behavior: parent keeps its declared type, subfield shape silently omitted, no warning.
- Deep ambient nesting (rejected at declaration; nothing to reflect).
- Reconciling self-referential nested id/model contracts (the existing KNOWN LIMITATION on `apply_model_id_requiredness!` stands: a `model:` subfield with a defaulted sibling `<field>_id` subfield may reflect its parent as required though runtime synthesizes it — the safe, stricter-than-runtime direction).
- Output schemas (`exposes` has no subfield mechanism).

## Design

### 1. Path-keyed subfield tree (new pre-pass)

A private pre-pass in `Axn::Reflection::Schema` normalizes `subfield_configs` into per-root trees before emission. Each node is `{config:, children: {wire_key => node}}`. Roots correspond to top-level field configs. A node's `config` is the `SubfieldConfig` for explicitly-declared nodes and `nil` for *implicit* nodes introduced by dotted segments (`on: "address.billing"` puts a config-less `billing` node between `address` and the subfield; `expects "bar.baz", on: :foo` puts a config-less `bar` between `foo` and `baz`).

For each subfield config, the anchor is resolved by walking `on:`: the root segment names a reader and is looked up among top-level configs first, then subfield configs; a subfield hit recurses into that config's own resolved node (ancestors are declared first, so resolution terminates). Remaining dotted `on:` segments and any dotted prefix of the field name become implicit child nodes keyed by symbolized segment; the config lands at the final wire-key segment. Reader→wire-key translation happens exactly once, in this pass — emission, requiredness derivation, and the dropped-set query all consume the finished tree, so they cannot drift.

**Representability check (same walk):** a *deep* config — one that is not a single-level subfield (its node sits at depth ≥ 2, whether via a dotted `on:`, a subfield parent, or a dotted name) — is *dropped* when any explicit ancestor on its chain is not a nesting site: the ancestor has `model:` (the client sends `<field>_id`, not the object) or fails `nestable_as_object?` (non-object type, or a mixed union like `type: [Hash, Array]`). Implicit nodes are always object-shaped (a runtime dig through them presumes hash access). Dropped configs are returned alongside the tree (the config list itself — the warning already names each field and its `on:` path, so the blocking ancestor's identity isn't carried). A *depth-1* subfield under a non-nesting parent is not dropped: as today, the parent keeps its declared type, the subfield contributes no schema, and no warning fires (see Non-goals).

**Same-node double declaration** (e.g. `expects "bar.baz", on: :foo` plus `expects :baz, on: :bar` where `bar` is a subfield of `foo`): the property is built from the first-declared config; requiredness is the union (required if any config at the node is required) and nullability the intersection (nullable only if all are). Runtime enforces every config independently, so this is stricter-than-runtime at worst — the safe direction.

### 2. Requiredness and nullability (one recursion)

The one-level rules generalize. A deep node can carry a default only via a dotted field NAME (a nested `on:` parent rejects `default:`); where one lands it is honored for that node's own optionality, but parent synthesis deliberately ignores it, so the synthesizer stays top-level-only:

- `required_within_parent?(node)` (membership in the parent's `required`): a node is omittable iff `usable_default?` (a usable default always rescues omission; its contents failing a child's validators remains the same accepted divergence as today), or `nil_accepted?` and no required descendant. An implicit node has no config — vacuously nil-tolerant — so it is required exactly when its subtree requires presence.
- `subtree_requires_presence?(node)`: any child is `required_within_parent?`. Naturally recursive — a required grandchild strands a nil ancestor just as a required child does.
- Nullability: a node's `type` gains `"null"` iff `nil_allowed?(config)` and not `subtree_requires_presence?` (the current single-level rule applied at every depth); implicit nodes are nullable iff no required descendant.
- Top-level `field_optional?` keeps its synthesis clause (subfield defaults materializing `{}`), with its required-child test upgraded to the transitive one. The synthesizer/shape-member machinery in `required_child?` remains top-level-only by construction: synthesis requires a defaulted child, and only depth-1 subfields can have defaults.
- The header divergence bullet in `schema.rb` ("a required deep subfield … doesn't force the parent required") is thereby fixed and deleted. `required_child?` stays the single source of truth for a parent's requiredness and nullability, now at every depth.

### 3. Emission and merge rules

`build_input`'s per-field body becomes a recursion over the tree:

- Explicit nodes build their property via the existing `build_property(config, subfield: true)`; implicit nodes emit a bare object property (`type: "object"` or `["object", "null"]` per the nullability rule) whose only content is its children.
- A node with children gets `properties`/`required` from its children and is forced to `type: object`/`["object", "null"]` with `format` dropped — today's `apply_nested_subfields!`, called recursively. An empty `required` is omitted. A non-nesting parent (which after the drop pass can only retain depth-1 children) keeps its declared type and emits no child properties, as today; its shallow children still participate in `required_child?`/`field_optional?` and model-id requiredness exactly as they do now.
- `model:` subfields at depth reuse the existing nested-model branch at each level: emit `<field>_id` into the enclosing node without clobbering an explicitly-declared sibling id, and `reject_null!` required ids after the level's loop. A model node is never a nesting site (its children were dropped during tree building).
- Shape merge precedence is unchanged: `apply_structured_schema!` runs inside `build_property` (shape members become `properties`), then subfield children overlay member properties at the same key, and `required` lists union. An *implicit* node colliding with an existing shape-member key merges into that property only if the member config is `nestable_as_object?` — the SAME predicate on the SAME member config that the drop pass (`SubfieldTree.blocking_ancestor?`) uses, so emission and the drop pass cannot disagree; otherwise the deep config is left in `dropped_deep_subfields` and warned like any non-object ancestor (a mixed-union member — `type: [Hash, Array]` — is not nestable, so it is dropped, not merged into a self-contradictory `anyOf`+forced-`object` property). This holds at every depth: when an implicit node merges into an object-shaped member, that member config is carried into the merged property's own children (emission) and along the ancestor chain (the drop walk), so a deeper implicit node colliding with a member of that member is tested against its nested `shape:` members by the same predicate.

### 4. Dropped set, warning, docs

`dropped_deep_subfields` is reimplemented as a projection of the tree builder's dropped list — same public signature and side-effect-free guarantee, but its meaning narrows to "structurally unrepresentable" (chain through a `model:`/non-object ancestor). Subfields rooted at `ambient_context` stay excluded from both schema and warning. The `schema_reflection.rb` warning text changes accordingly (no longer "flatten to single-level"; instead naming the non-object/model ancestor). The `KNOWN LIMITATION` header on `build_input` is replaced by a short note on the remaining structural exclusions. `docs/reference/class.md` and the CHANGELOG Unreleased section are updated; since PRO-2871's entry is still unreleased, it is amended rather than appended to.

## Testing

Extend `spec/axn/reflection/schema_spec.rb` with a deep-nesting section:

- Each of the three forms alone, and composed (dotted `on:` under a subfield-of-subfield, dotted names at depth).
- Alias (`as:`/`prefix:`) chains: `on:` referencing an aliased reader at each hop, properties keyed by wire key.
- Implicit-intermediate requiredness/nullability in both directions (required leaf → required non-null intermediates; all-optional leaf → omittable nullable intermediates).
- Transitive required propagation through an `optional:` explicit intermediate (the fixed divergence), and the defaulted depth-1 parent whose usable default keeps it omittable despite a required deep child.
- `model:` at depth, including an explicitly-declared sibling id subfield (no clobber) and `reject_null!` on required ids.
- Shape-member + subfield merge at depth, including the implicit-node-vs-scalar-shape-member drop case, at both a top-level member and a member of a member (the carried member config).
- Same-node double declaration (first-config property, union requiredness).
- Drops through `model:`/`type: Array`/mixed-union ancestors feeding the narrowed `dropped_deep_subfields`; ambient exclusion unchanged.
- Runtime-truth checks for the requiredness cases: `call` representative actions omitting/nulling each path and assert the outcome agrees with the schema's `required`/nullability (stricter-only divergences asserted as such).

`spec/axn/core/schema_reflection_spec.rb` warning specs update to the narrowed trigger (a representable deep subfield no longer warns; an unrepresentable one still does, once per class).

## Alternatives considered

- **Iterative deepening** (re-apply the shallow mechanism per level, synthesizing per-segment configs): requiredness propagates bottom-up while passes run top-down, forcing re-patching of emitted properties, and synthetic configs break the identity-based (`object_id`) bookkeeping `dropped_deep_subfields` relies on. Rejected.
- **Emit-time recursion without a prebuilt tree** (re-scan `subfield_configs` per level during emission): path-resolution rules (aliases, dotted segments) get re-implemented in every consumer — emission, `required_child?`, and the dropped-set query would each traverse independently, inviting mirror drift. Rejected.
