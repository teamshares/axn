# Full kwarg parity for method-calling expectations (PRO-2903)

Follow-up to PRO-2898 (`method_call: true`). PRO-2898 made subfield method dispatch an explicit opt-in and left `preprocess:`/`coerce:` *declarable but silently inert* on a `method_call:` subfield. This ticket makes them actually apply — and, having established that the read path is the correct home for subfield transforms, migrates *all* subfield `preprocess:`/`coerce:`/`default:` off the pre-validation write-back passes onto the read path.

## Problem

`default:` already composes with `method_call:`: PRO-2889 made subfield defaults resolve on the *read* path (`ContractForSubfields.resolve_value`), so a `nil` method result falls back to the declared default. `preprocess:` and `coerce:` do **not** compose: they are implemented as pre-validation **write-back passes** (read the current value, transform it, write it back into `@context.provided_data`, re-read). A `method_call:` value is derived at read time and never lives in `provided_data`, so the write-back lands where the read never looks and the transform is inert.

## Decision

Resolve **all** subfield `coerce:`/`preprocess:`/`default:` on the read path (`resolve_value`), and remove the subfield write-back entirely. Top-level fields keep their write-back (they read `provided_data` directly through the context facade — there is no `resolve_value` indirection for them, so write-back is their only resolution mechanism).

This is not a new paradigm. PRO-2889 already moved subfield **defaults** onto the read path as value-level resolution (lazy, memoized, non-materializing) and accepted the "a proc read early then re-read after the memo clear runs twice" trade. This ticket extends that same, already-blessed model to `preprocess:` and `coerce:`, then deletes the now-redundant write-back apparatus.

### Why read-only is safe for subfields

Write-back buys two things; both evaporate for subfields:

1. **It is the resolution mechanism for top-level fields** — a top-level reader reads `provided_data` directly, so write-back is the only place its transforms become visible. This is why top-level stays on write-back. It says nothing about subfields, which resolve through `resolve_value`.
2. **It materializes transforms into raw `provided_data` for direct consumers.** Every subfield instance of this was audited and cleared:
   - **Async** serializes the raw call kwargs (`AsyncSerialization.serialize(kwargs)`), *not* `@context.provided_data`. The worker re-runs the full pipeline at perform through readers/`resolve_value`. Subfield write-back never reached the enqueued payload.
   - **Ambient** subfields already reject `coerce:`/`preprocess:`/`default:` at declaration, so they never carried write-back transforms.
   - **Logging / `inputs`** read only top-level declared fields; subfields are excluded.
   - **Model-consistency** reads `<field>_id` raw off the resolved parent. Removing subfield default write-back *removes* the `_id_default_would_conflict_with_present_record?` guard's reason to exist — the check then sees only genuinely caller-supplied ids. The defaulted-id-still-resolves-a-record path is already handled on the read path by `resolve_model_via_sibling_id`.
   - **Facet prep** (`prepare_inbound_for_facets!`) resolves subfields lazily on read, exactly as `model:` readers already do there.

### Observable behavior change (`[BREAKING]`)

Removing subfield write-back is not purely behavior-preserving. A subfield `default:`/`preprocess:` write-back today doesn't only resolve the child — it **materializes the parent**, observable through the *parent's own reader*. After commit 2:

- **A subfield default/preprocess no longer materializes or mutates its parent.** The parent reader returns the caller's value unchanged; the child still resolves its default via the read path (value-level, PRO-2889).
- Example: `expects :note, on: :payload, default: "d"` called with `payload: nil` — today `payload` reads back `{note: "d"}`; after, `payload` reads `nil` and `note` reads `"d"`.
- The setter write-through for a settable-object parent (a `Struct`) — the exact in-place caller mutation PRO-2898 flagged and PRO-2908 targets — is eliminated for subfields.

Accepted deliberately: axn is pre-alpha and subfields are lightly used. `[BREAKING]` CHANGELOG entry. In `subfield_write_back_matrix_spec.rb` (17 examples) exactly the 4 that assert a *synthesized parent shape* (matrix:20, :107, :119, :134) get rewritten to assert the new non-materializing behavior; the rest (child-value and non-mutation assertions) stay green unchanged.

### Known behavior refinement

A subfield that has a `preprocess:` **and** no validators **and** is never read by user code: its proc fires eagerly under write-back but not under read-path (nothing triggers the read). This is marginal (a field whose only effect is an unread preprocess side-effect is an anti-pattern), is *identical* to how PRO-2889 already treats such a field's `default:`, and is documented. Not a correctness hole.

## Approach — two commits in one PR

The hazard is regressing the *already-working non-method-call subfields* while re-homing them. Isolating that in its own commit means a snag there strands only the cleanup, not the parity fix.

### Commit 1 — read-path parity for method-call-crossing subfields (the ticket's ask)

In `resolve_value`, after the leaf extract, apply `coerce → preprocess → default-fallback` **only when the config's resolution crosses a method_call hop** (`config.method_call`, or any ancestor node on its chain dispatches). Order mirrors the top-level pass order (`apply_inbound_coercion!` → `apply_inbound_preprocessing!` → `apply_defaults!`).

- Extract the coerce-value core (already `Reflection::Coercion.coerce_value` + the `coerce_field_inbound?` tri-state gate, including `coerce_input_types`) and the preprocess-value core (the `apply_inbound_preprocessing!` inner block + its `ContractErrorHandling` wrapping) into shared helpers callable from both the executor write-back passes and `resolve_value`, so the two routes can't drift — mirroring how `Internal::FieldConfig.resolve_default` single-sources defaults.
- Gate `resolve_value`'s new branch on the *exact complement* of what the write-back passes skip (`_resolution_crosses_method_call?`), single-sourced, so a subfield's transform runs on exactly one route.
- `coerce_input_types` (the whole-action flag) reaches method-call-crossing coercible subfields through the shared coercion helper's gate.
- Preprocess drop-on-nil-parent semantics: when the resolved parent is nil the subfield is absent — skip preprocess (return the extracted nil, then default-fallback), matching write-back's "never synthesize the parent" drop.

At the end of commit 1: full parity is green, no double-application, `_resolution_crosses_method_call?` still gates the write-back skips.

### Commit 2 — flip all subfields onto the read path, delete the write-back apparatus

- `resolve_value` applies `coerce → preprocess → default` for **every** subfield (drop the method-call gate on the new branch).
- The three write-back passes (`apply_inbound_coercion!`, `apply_inbound_preprocessing!`, `apply_inbound_defaults!`) become **top-level only** (depth-0). The `_resolution_crosses_method_call?` skip and the whole nested-materialization apparatus are deleted:
  - `_write_chain_materializable?`, `_synthesizable_node?`, `_default_clobbers_model_route?`, `_id_default_would_conflict_with_present_record?`, `_sibling_model_route_for_id`, `_default_chain_hash_writable?`, the `{}`-synthesis line, and the depth-generalized `_current_value_at`/`_write_value_at!`/`_cow_write` walkers (kept only insofar as top-level depth-0 needs them — depth-0 assigns `provided_data[key]` directly, so the nested walkers likely go entirely).
  - `_resolution_crosses_method_call?` itself is removed once nothing gates on it.
- Verify each deleted guard's intent is preserved by the read path (e.g. model-route clobbering can't happen when nothing writes back; the sibling-id rescue stays on the read path).

At the end of commit 2: one resolution path for subfields, top-level unchanged, ~150 lines of write-back safety machinery deleted.

## Testing

- `preprocess:` and `coerce:` compose with `method_call:` (leaf) and with a subfield nested under a method_call parent — applied to the resolved value, reader and validation agreeing.
- Ordering (`coerce → preprocess → default`) matches top-level behavior.
- `coerce_input_types` reaches method-call-crossing coercible subfields.
- **No in-place mutation** of caller-supplied objects on the read path (assert the caller's object is unchanged after the call — the wedge this ticket establishes).
- Regression: `default:` composition (PRO-2889) continues to hold.
- Commit 2 regression: the full existing non-method-call subfield `default:`/`preprocess:`/`coerce:` suite stays green through the read path — nested defaults, model-route non-clobbering, model-consistency, `coerce_input_types` at depth — EXCEPT the 4 parent-materialization assertions (matrix:20, :107, :119, :134), which are rewritten to assert the parent reader returns the caller's value unchanged while the child still resolves.
- Rewrite the method_call_spec "inert" block to assert composition.

## Docs / CHANGELOG

- Remove the "silently inert / skipped entirely / planned (PRO-2903)" notes in `docs/reference/class.md` and the PRO-2898 CHANGELOG entry; state that `preprocess:`/`coerce:` compose with `method_call:`.
- `[BREAKING]` CHANGELOG entry for PRO-2903: subfield `default:`/`preprocess:` no longer materialize/mutate the parent (child still resolves via the read path).
- Update the executor comments that frame the skips as "keeps them inert (PRO-2903)".

## Follow-up (separate ticket) — PRO-2908

Migrate **top-level** fields off write-back too (the full "stop mutating caller-supplied objects" endgame). Larger: reroutes the context facade — the library's most fundamental input read — plus every remaining raw-`provided_data` consumer. Out of scope here.
