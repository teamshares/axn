# Restore full ambient subfield symmetry: `default:`/`preprocess:`/`coerce:` + `shape:` (PRO-2912)

**Ticket:** [PRO-2912](https://linear.app/teamshares/issue/PRO-2912/axn-restore-full-ambient-subfield-symmetry-defaultpreprocesscoerce) — part of the alpha interface-consistency slate (PRO-2908/2925/2912/2926/2927).

## Problem

Ambient (`on: :ambient_context`) subfields carry declaration carve-outs no other `on:` parent has: `default:`, `preprocess:`, `coerce:`, and `shape:` all raise at declaration, and `user_facing:` is rejected. These were justified by the *write-back* resolution model: coercion/preprocess/default wrote transformed values into `provided_data`, which ambient is never read from, so applying them to an ambient value would silently no-op — better to reject than to lie.

That mechanism is gone. PRO-2903 moved subfield resolution to a non-mutating **read path**: ambient subfields already resolve through `ContractForSubfields.resolve_value` → `_apply_read_path_transforms` (coerce + preprocess) → value-level default, exactly like every other subfield. No wire write-back occurs. The guards now block capabilities the runtime already supports; they are stale.

The carve-outs split two ways:

- **Mechanism-driven** (`default:`/`preprocess:`/`coerce:`, and `shape:`'s schema-mootness): justified only by write-back → collapse to symmetry.
- **Nature-driven** (`user_facing:`): ambient values are framework-supplied, not caller input, so classifying a violation as caller-facing is a category error *regardless of resolution mechanism* → **keep rejected**.

### Relationship to in-flight PRO-2908

PRO-2908 removes the *remaining* write-back, which is **top-level only** — it migrates top-level fields onto the same depth-0 `resolve_value` read path subfields already use. It does not touch the ambient read path this ticket depends on; it converges the rest of the system onto the model ambient already follows. Step 1 is therefore **not gated on PRO-2908** and stays valid after it lands (the world PRO-2908 produces — one non-mutating read-path model everywhere — is exactly the world Step 1 assumes). The only interaction is mechanical: both edit `contract_for_subfields.rb` and `contract.rb`, so whichever merges second rebases over the other. If PRO-2908 refactors the shared read-path helpers, ambient inherits the change for free (same code path).

## Decision

Restore full symmetry in one PR, two steps:

1. **Allow `default:`/`preprocess:`/`coerce:` on ambient subfields** by removing the declaration guards. The read path already applies all three.
2. **Allow `shape:` on ambient subfields for the leaf-copy case** (a shape-carrying ambient node with no subfield children), reject the non-leaf case at declaration, and close the sensitive-masking gap on the ambient logging path.

`user_facing:` stays rejected. All `_on_roots_at_ambient?` gating semantics (guards fire at any depth: direct, dotted `on:`, nested-under-ambient) are preserved.

---

## Step 1 — `default:`/`preprocess:`/`coerce:` on ambient subfields

### What changes

- Remove the `default:`/`preprocess:` rejection (`contract_for_subfields.rb:245`) and its write-back rationale comment (`:238–251`).
- Remove `_reject_ambient_coerce!` (`:330`) and its call site (`:320`), plus its rationale comment (`:326–337`).
- Keep `_reject_ambient_shape!` handled by Step 2; keep the `user_facing:` rejection (`:224`) untouched.
- Update the surviving nesting comment (`:230–236`) so it no longer references the removed `default:`/`preprocess:`/`coerce:` carve-outs.

No runtime resolution code changes. `resolve_value` (`:85`) and `_apply_read_path_transforms` (`:115`) already apply coerce → preprocess → value-level default to every subfield value, ambient included.

### Why it's correct — the one real check

The concern is that a defaulted/coerced/preprocessed ambient value must **validate against the transformed value** (what the reader returns), not the raw one. This already holds: inbound validation for a subfield reads through the action's generated reader when one exists (`validation/fields.rb:26`), else through `resolve_value` directly (`:29`). Both apply the transforms. Reader path and validation path share one resolution, so symmetry is already true at validation — only the declaration guards were stale.

### Behavior by example

```ruby
expects :locale, on: :ambient_context, default: "en"
# ambient provides no :locale → reader returns "en"; validation sees "en"

expects :count, on: :ambient_context, type: Integer, coerce: :integer
# ambient provides count: "5" → reader returns 5; validation sees 5

expects :tag, on: :ambient_context, preprocess: ->(v) { v&.strip }
# ambient provides tag: " x " → reader returns "x"; validation sees "x"
```

A nested/deep ambient value behaves identically (PRO-2909 forms): the guards were `_on_roots_at_ambient?`-gated, so removing them restores symmetry at every depth, and `_filter_to_declared` still drops undeclared siblings.

### Edge: preprocess on an absent ambient value

`_apply_read_path_transforms` skips preprocess when the parent is `nil`. The ambient parent is the filtered ambient hash (`{}` at worst, never `nil`), so preprocess runs on an absent leaf's `nil` value — identical to any other subfield whose parent hash is present but childless (the PRO-2903 model). Value-level `default:` then fills a `nil` result. This is the intended symmetric behavior, not an ambient special case.

---

## Step 2 — `shape:` on ambient subfields

### The leaf-copy insight (spike confirmed)

Shape's schema job is moot on ambient (ambient is excluded from `input_schema`), but its **validation** job is real: fail loudly if the ambient provider wasn't set up correctly. A shape-carrying ambient node with **no subfield children** is treated as a leaf by `_filter_ambient_node` (`ambient_context.rb:155`, `child.children.empty?`) and its whole value is copied. The `request` reader then returns that copied value, and shape validation runs against it through the normal subfield validation path (`_collect_contract_failures` → `collect_errors` → reader → `ShapeValidator`). No merge of the shape-member tree into the ambient filter is needed.

This covers every shape-only shape: leaf (`expects :request, on: :ambient_context, shape: {...}`), a shape node reached via an implicit intermediate (`expects :request, on: "ambient_context.meta", shape: {...}` — `request` is still a childless leaf in the tree), and nested-member shapes (a member whose validations carry their own `:shape`, which `ShapeValidator` recurses into unchanged).

### Reject the non-leaf case at declaration (refinement over the ticket)

The ticket frames the rejection as "a key declared as **both** a subfield child and a shape member on the same ambient parent." The correct invariant is broader and simpler to state:

> **A shape-carrying ambient node must be a filter-leaf — no subfield children, OR a `model:` node** (whose children read off the resolved record, so `_filter_ambient_node` copies it whole regardless — the same leaf test the filter uses).

*(Implementation refinement: the leaf test reuses `_filter_ambient_node`'s exact predicate `children.empty? || _ambient_model_node?(node)`, single-sourced, so a `model:` ambient node may carry a shape and children together — the filter copies it whole and the shape validates against the record. A non-`model:` shape node with children is the rejected case.)*

Key-overlap rejection misses a real broken case:

```ruby
expects :request, on: :ambient_context, shape: { token: String }
expects :foo, on: :request                 # non-overlapping child
```

No key overlaps, yet `request` is now non-leaf, so `_filter_ambient_node` reconstructs it from children only (`{foo: ...}`) and the shape's `token` member validates against a hash the filter already dropped `token` from → a spurious "token could not be read." The leaf-only rule catches this and the overlap case (`shape: {token:}` + `expects :token, on: :request`) together — closing the whole class rather than the one flagged instance.

**Implementation.** Add a sibling declaration check alongside the existing `_check_ambient_subfield_contradictions!` (`ambient_context.rb:54`), reusing the same candidate-tree machinery: `_check_ambient_shape_placement!(candidate_subfields)` builds the candidate ambient `SubfieldTree` (`SubfieldTree.build([_synthetic_ambient_root], ambient)`, exactly as `_ambient_subfield_tree` does for committed configs) and rejects any node whose configs carry a `:shape` validation **and** whose `children` is non-empty. It's called from the same declaration site (`contract_for_subfields.rb:269`), right after the contradiction check. (Kept a sibling rather than folded in because `SubfieldContradictions.check!` builds its tree internally; the extra candidate-tree build is declaration-time only and O(configs), and each method stays single-purpose.) The message points at declaring the nested structure **one** way: shape-only for validation, or subfields for validation + readers + `sensitive:` — never both on one ambient node.

Then remove `_reject_ambient_shape!` (`contract_for_subfields.rb:347`), its call site (`:321`), and the line-344 deferral comment.

### Sensitive-masking: close the ambient path (refinement 2)

Ambient values reach logs in exactly **one** place: `execution_context` (`contract.rb:1131–1133`), used for exception reporting. Normal call logging (`inputs_for_logging`/`_context_slice`) slices to declared top-level fields only and never carries ambient. The ambient path applies `ambient_filter.filter(ambient_context)` — `ActiveSupport::ParameterFilter` alone.

- **Hash-valued shapes (the normal case): already correct with zero new code.** `_sensitive_candidate_configs` (`contract.rb:263`) already walks `subfield_configs` and flattens shape members, so an ambient shape's `sensitive:` member name is in `sensitive_fields` the moment the guard is gone. ParameterFilter redacts that key at any depth inside the ambient hash.
- **Non-Hash shape values (the gap): object-backed or malformed values** ParameterFilter can't descend into. PR #176's `_mask_unfilterable_shapes` handles this for regular fields/subfields but is not wired into the ambient path, so a sensitive member nested in an object-backed ambient shape would print whole.

**Fix.** Route the ambient hash through wholesale-masking before the ParameterFilter, scoped to ambient shape paths:

1. Refactor `_mask_unfilterable_shapes(data, action_instance)` to accept the paths explicitly: `_mask_unfilterable_shapes(data, shape_paths, action_instance)`. Existing callers pass `_sensitive_shape_paths(action_instance)` (unchanged behavior).
2. Add `_sensitive_ambient_shape_paths(action_instance)`: walk the ambient subfield tree (`_ambient_subfield_tree`), and for each ambient config whose shape carries a sensitive member, yield `[wire_path_within_ambient, shape]`. The ambient tree's wire paths are rooted at the synthetic `:ambient_context` segment, so drop that leading segment — the mask is applied to the ambient *value* (the hash the reader returns), not a hash wrapped under an `:ambient_context` key.
3. In `execution_context`, mask before filtering: `ambient_filter.filter(_mask_unfilterable_shapes(ambient_context, _sensitive_ambient_shape_paths(self), self))`, kept inside the existing `_safe_execution_context_slice` guard so a failing provider still degrades to `{}` rather than propagating.

This reuses the exact PR #176 masking helpers (`_mask_value_at_path`, `_mask_opaque_or_preserve`, `_mask_shape_value`) — no re-derivation of masking logic; only the path source differs.

---

## What we are NOT doing

- **No filter-merge into `_filter_ambient_node`.** The leaf-copy path makes it unnecessary for the supported case; the non-leaf case is rejected at declaration, so the filter never needs to reconstruct a shape node from a merged member tree.
- **No `user_facing:` on ambient.** Nature-driven rejection stays.
- **No change to `input_schema`.** Ambient remains excluded; shape's schema-emission job stays moot on ambient (only its validation job is restored).
- **No change to the normal (non-exception) logging path.** Ambient is not carried there.

## Testing

**Step 1**

- `coerce:` / `preprocess:` / `default:` each applied to an ambient subfield value, observed on **read** (the reader) AND at **validation** (a type check that would fail on the raw value but pass on the transformed one).
- Absent provider key → `default:` fills; present provider value → `coerce:` transforms; `preprocess:` transforms.
- Nested/deep ambient (PRO-2909 forms) still filter correctly with these options present.
- `user_facing:` still rejected on ambient (direct + nested).
- The three existing rejection specs (`ambient_context_spec.rb:122,131`; the nested `default:`/`preprocess:`/`coerce:` rejections at `:497,507,517,527`; `coercion_spec.rb`) flip from "rejects" to "applies."

**Step 2**

- Shape-only ambient parent validates: leaf, via-implicit-intermediate, and nested-member forms — success and a failing-member case each.
- Non-leaf shape node rejected at declaration: overlap-key form AND non-overlapping-child form. (Only the shape-then-child order is reachable — a child's `on:` requires its parent already declared, so the shape-carrying parent must come first; the check is order-independent regardless.)
- Sensitive shape member on ambient masked in exception context: Hash-valued (ParameterFilter path) AND non-Hash/object-backed (wholesale-mask path); a non-sensitive sibling survives the Hash case; `nil` absent data is preserved, not masked.
- The existing shape-rejection specs (`ambient_context_spec.rb:371–392`) flip to acceptance / non-leaf-rejection.

## Files touched

- `lib/axn/core/contract_for_subfields.rb` — remove three guards + stale comments; update the nesting comment.
- `lib/axn/core/ambient_context.rb` — add the `_check_ambient_shape_placement!` sibling declaration check (candidate-tree walk).
- `lib/axn/core/contract.rb` — parametrize `_mask_unfilterable_shapes`; add `_sensitive_ambient_shape_paths`; wire wholesale-masking into `execution_context`'s ambient slice.
- `spec/axn/core/ambient_context_spec.rb`, `spec/axn/core/coercion_spec.rb` — flip rejections; add read/validation/shape/sensitive coverage.
- `CHANGELOG.md` — feature entry (restored ambient symmetry).
- Docs — ambient/subfield reference: note that `default:`/`preprocess:`/`coerce:`/`shape:` are now supported on ambient subfields (shape leaf-only), `user_facing:` still not.
