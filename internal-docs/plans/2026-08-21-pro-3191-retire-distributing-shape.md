# Retire the distributing `shape:` Implementation Plan

**Goal:** Stop accepting a raw `shape:` kwarg that asks to distribute over an Array's elements — the exception `shape:` used to carry only because `of:` (pre-PRO-3166) had no way to name an element's own members. The block form keeps working; only the raw-Hash-kwarg surface is retired.

**Architecture:** One new guard, `_reject_distributing_shape!(carrier, where)`, checked at every position a raw `shape:` kwarg can be written (field-level `expects`/`exposes`, a block-declared member's own kwarg, a duck-typed raw member), ahead of wherever a block would otherwise overwrite the same slot. It refuses two conditions: `shape:` beside a `type:` naming `Array`, and a raw shape hand-writing `container: Array` regardless of the enclosing type (a divergence found while implementing — see spec). Two now-dead branches in `_snapshot_member_shape!` (the distributing-depth offset for a MEMBER's own shape) are removed, since no legal declaration can reach them once the guard is in place.

**Tech Stack:** Ruby 3.2–3.4, ActiveModel 8.x, RSpec. No Rails dependency in any file touched here.

**Spec:** `internal-docs/specs/2026-08-21-pro-3191-retire-distributing-shape-design.md`

**Predecessor:** PRO-3166 (`internal-docs/plans/2026-08-19-pro-3166-recursive-of.md`), which canonicalized the flat spelling forward in storage. This ticket retires the surface that canonicalization used to accept.

## Global Constraints

- **Works outside Rails.** Every file touched here is loaded by plain `require "axn"`. All specs go under `spec/`; nothing here needs `spec_rails` (its suite is re-run as a smoke check, not extended).
- **Fail at declaration, not runtime.** Both refusals raise `ArgumentError` when the class is defined.
- **Never dispatch a caller's method from a guard or error path.** Use `Internal::ShapeGraph.hash_or_nil` / `.carries_key?`; compare classes with `equal?` (`::Array.equal?(x)`, never `x == ::Array`).
- **Ordering is load-bearing.** Each guard call must run on the caller's raw `validations[:shape]`, strictly before the block form (`_build_shape`) would overwrite that same key — verified by an inverse mutation (moving the guard after the block-build broke 11 legitimate block-form specs).
- **Never assert on `Hash#inspect` text.**
- **CHANGELOG** every user-visible change under `## Unreleased`, tagged `[BREAKING]`.
- Run `bundle exec rspec` and `bundle exec rubocop` clean before treating a task as done.

## File Structure

**Modified:**
- `lib/axn/core/contract/shape_declaration.rb` — the new guard, its two messages, the call site inside `_snapshot_member_shape!`, and the two dead branches removed from that same method.
- `lib/axn/core/contract.rb` — the two field-level call sites (`expects`, `exposes`) and the one member-level call site (`_build_shape_member`); two comments (`_folded_element_container`) updated to state the surviving (block-only) reachability rather than "the surface still accepts the flat spelling".
- `docs/reference/class.md` — one new bullet under the shape-blocks section.
- `CHANGELOG.md` — one `[BREAKING]` bullet under `## Unreleased` → `### Fixed`.
- Eight spec files carrying the retired flat spelling, rewritten to the bag or block form: `property_name_collision_spec.rb` (9 declarations), `canonical_storage_spec.rb` (5, one describe block re-pointed at block-vs-bag), `user_facing_spec.rb` (2), `shape_contracts_spec.rb` (3, plus a new failure-grid describe), `sensitive_shape_members_spec.rb` (2), `schema_collapse_invariant_spec.rb` (2), `recursive_of_spec.rb` (1, moved to the Hash-exemption spelling), `stored_shape_traversal_spec.rb` (0 — its two `container: Array` occurrences construct `internal_field_configs` directly, bypassing the guarded DSL entirely; confirmed unaffected).

**Not created:** no new files. The failure grid lives inside the existing `shape_contracts_spec.rb`, under a new `"retiring the distributing shape: (PRO-3191)"` describe, rather than a dedicated spec file — the surface this ticket removes is small enough that a new file would fragment coverage that already lives beside the block-form specs it contrasts with.

---

### Task 1: The guard and its two messages

**Files:**
- Modify: `lib/axn/core/contract/shape_declaration.rb`

- [x] **Step 1: Write the failing tests.** Added the `"retiring the distributing shape: (PRO-3191)"` describe to `shape_contracts_spec.rb` — every refused spelling from both conditions, plus a "what still declares" positive-control group.
- [x] **Step 2: `_reject_distributing_shape!(carrier, where)`.** Checks (a) via the existing `_distributing_shape?(carrier)` predicate (needs only `type:`, so checked unconditionally) and (b) via `Internal::ShapeGraph.hash_or_nil(carrier[:shape])` then `::Array.equal?(shape[:container])` (checked only once the shape is confirmed to be a Hash — a non-Hash shape is `_reject_unshaped_shape!`'s defect, not this one's). Registered private alongside the file's other declaration-time helpers.
- [x] **Step 3: Verify.** All new specs pass; `bundle exec rubocop` clean on the file.

### Task 2: Wire the guard into the four call sites

**Files:**
- Modify: `lib/axn/core/contract.rb`, `lib/axn/core/contract/shape_declaration.rb`

- [x] **Step 1: `expects`.** Called right after `_partition_field_options`, before `validations[:shape] = _build_shape(...) if block`.
- [x] **Step 2: `exposes`.** Same position, same reasoning.
- [x] **Step 3: `_build_shape_member`.** Called right after its own `_partition_field_options`, before its own `_build_shape(...) if subblock` — closes the case where a block-declared member carries a raw `shape:` kwarg AND a subblock, which would otherwise silently discard the raw one.
- [x] **Step 4: `_snapshot_member_shape!`.** Called before the pre-existing `_reject_unshaped_shape!`, at the one place a duck-typed raw member's own `:shape` is first read. Verified by probe that a block-form member's shape is already folded into its `of:` bag by the time this runs (in `_build_shape_member`'s own pre-pass), so this call site never sees a legitimate distributing shape to reject.
- [x] **Step 5: Verify.** Full suite green (6330 examples). Mutation audit: disabling condition (a) fails exactly 3 specs, disabling (b) fails exactly 3 specs, moving the `expects` guard after the block-build fails 11 legitimate block-form specs across two files. Restored each mutation and re-diffed against a clean checkout to confirm no residue.

### Task 3: Remove the two branches this makes dead

**Files:**
- Modify: `lib/axn/core/contract/shape_declaration.rb`

- [x] **Step 1: Remove** the `depth = _distributing_shape_depth(validations, walk.depth)` offset and the `rungs = _distributing_shape?(validations) ? 2 : 1` charge inside `_snapshot_member_shape!` — both always resolved to their non-distributing value once Task 2 landed.
- [x] **Step 2: Prove they were dead**, not merely unreachable in the new specs. Built a pure block-form distributing chain (`type: Array do field :m, type: Array do … end end`, repeated) and probed its declarable depth against the branch base (`5e309e17`) and against this branch: identical (31 levels legal, 32 raises), matching the pre-existing 32-level cap CHANGELOG entry. A Hash-chain baseline (64/65) matched too.
- [x] **Step 3: Handle the one test this orphans.** `canonical_storage_spec.rb`'s "charges a reused DISTRIBUTING member shape its two rungs" tested exactly the removed path via two sibling members sharing one raw shape object by identity. Deleted with a comment: that scenario can no longer be constructed by any legal declaration (raw is refused; a block always builds a fresh Hash per call site, so no two block positions can share an object). Its non-distributing sibling test is untouched.
- [x] **Step 4: Verify.** Full suite still green; `_distributing_shape_depth` retains its one remaining (legitimate) caller at field level.

### Task 4: Sweep and rewrite existing flat-spelling specs

**Files:**
- Modify: the eight spec files listed above.

- [x] **Step 1: Enumerate.** Ran the full suite before any spec changes to get the complete failure list (16 failures across 6 files, plus one the initial grep sweep had missed inside `property_name_collision_spec.rb`'s `wide_contract` helper).
- [x] **Step 2: Rewrite each**, preserving the original assertion's intent:
  - Declarations whose element class is a plain klass → the `of:` bag (`of: { klass: X, shape: {...} }`).
  - Declarations whose element class is scalar or unconstrained (where the bag form would itself raise, per PRO-3166's scalar/union-`klass:` refusal) → the block form.
  - Declarations testing a defect specific to the raw kwarg (user_facing bypass, duck-typed members, sensitive redaction) but not to distribution → moved to `type: Hash`, dropping the now-superfluous `container: Array`.
  - The one test that deliberately spent both of a field's budget-sharing edges from one declaration (`recursive_of_spec.rb`) → moved from `type: Array, shape: … , of: …` (now refused) to `type: Hash, shape: …, of: { values: … }` (PRO-3166's Hash exemption — the only other spelling where a field's own `shape:` and `of:` coexist).
  - `canonical_storage_spec.rb`'s block-vs-bag equivalence describe → block-chain builder (`proc`-based recursive `field` calls) substituted for the raw-shape-chain builder it used to compare against the bag form.
- [x] **Step 3: Verify.** `bundle exec rspec` and `bundle exec rubocop` clean across the full suite; `spec_rails` re-run as a smoke check (368 examples, untouched by this change).

### Task 5: Docs, CHANGELOG, downstream sweep

**Files:**
- Modify: `docs/reference/class.md`, `CHANGELOG.md`

- [x] **Step 1: Docs.** One bullet under `{#shape-blocks}` stating the rule for both conditions and pointing at the two surviving spellings.
- [x] **Step 2: CHANGELOG.** One `[BREAKING]` bullet under `## Unreleased` → `### Fixed`, placed beside the PRO-3166 distributing-chain-depth entry it is the sequel to. States what changed, that the block form is unaffected, and that condition (b) was a live divergence rather than a working feature losing support.
- [x] **Step 3: Downstream sweep.** Direct grep across `axn-mcp`, `axn-openapi`, `axn-ruby_llm`, `axn-webhooks`, `data_shifter`, `slack_sender`, `os-app`, `buyout-app`, `invoice-app`, `teamshares-rails` for the flat spelling and for direct `config.validations[:shape]` reads: zero hits, every `shape:` usage found is block-form. `rake downstream:check` from the main checkout: all gems' version constraints compatible.
