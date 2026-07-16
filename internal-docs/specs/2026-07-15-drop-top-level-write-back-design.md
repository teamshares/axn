# Drop user-modifying top-level write-back behavior (PRO-2908)

Follow-up to PRO-2903, which moved **all subfield** `coerce:`/`preprocess:`/`default:` resolution onto the read path (`ContractForSubfields.resolve_value`) and deleted the subfield write-back apparatus. This ticket finishes the job for **top-level fields**: it moves their `coerce:`/`preprocess:`/`default:` resolution off the pre-validation write-back passes onto the same read-path seam, then deletes the write-back apparatus entirely.

## Problem

The inbound pre-validation passes (`Executor#apply_inbound_coercion!` / `#apply_inbound_preprocessing!` / `#apply_inbound_defaults!`) resolve a top-level value and then **write it back into** `@context.provided_data` (`_write_value_at!` → `provided_data[key] = value`). Top-level fields still do this because a top-level reader reads `provided_data` directly through the context facade (`InternalContext#_context_data_source[field]`) — there is no `resolve_value` indirection for them, so write-back is currently their only resolution mechanism.

Two problems follow:

1. **`provided_data` is no longer pristine.** After `with_contract` runs, `@context.provided_data` holds transformed values, not what the caller sent. Every raw-`provided_data` consumer (the context facade itself, the `<field>_id` reader, model-consistency, the outbound copy-forward, the strand diagnostic, exception-report `:inputs`) reads post-transform values, and any future consumer inherits that hazard silently. This is the same in-place-mutation concern raised in PRO-2898 review, now scoped to the last place it survives.
2. **Top-level and subfield resolution are asymmetric.** Subfields resolve lazily, value-level, non-materializing on the read path; top-level fields resolve eagerly by mutation. That asymmetry is a standing tax on the next two tickets (ambient collapse, top/subfield symmetry), each of which would otherwise have to migrate top-level fields itself.

## Decision

A top-level field is structurally **a subfield whose parent is `provided_data` and whose leaf is the wire key** — it is already indexed in `_resolved_subfields.index` as the depth-0 `ResolvedPath` (`wire_path: [field]`, `ancestors: []`, `parent_index: 0`). So we resolve top-level `coerce:`/`preprocess:`/`default:` on the **same read-path seam** the subfields already use (`ContractForSubfields.resolve_value`), reroute the context facade through it, and delete the top-level write-back passes.

This reuses the seam rather than adding a parallel top-level resolver (AGENTS.md "reuse the seams — a parallel path is a new thing to keep consistent forever"). The whole read-path model — lazy, memoized (`@__resolve_value_cache`, already cleared at the pipeline boundary), non-materializing, value-level `default:` (PRO-2889), `coerce → preprocess → default` ordering — is already blessed for subfields; this extends it to depth 0.

### Model fields: full unification (Option A)

A defaulted or sibling-supplied `<field>_id` reaches the top-level model reader **today only because write-back materialized the id into `provided_data`**. Once write-back is gone, the model reader must consult the *resolved* id — which is exactly what the subfield side already solved with `resolve_model_via_sibling_id`. We route top-level model readers through the **same** machinery via a shared `resolve_model_value(action, config, options)` (resolve parent → resolve record → sibling-id rescue → record-supplying default fallback), used by both the facade model reader and `_define_subfield_model_reader`.

The alternative — keeping the facade model reader reading raw `provided_data` and re-implementing the id fallback inline — was rejected: it would re-derive the blank-token guard, the "present id that failed its lookup stays nil" rule, and `usable_id_token_default?` route-selection (which route wins when several `<x>_id` declarations merge onto one wire key), all of which already live inside `resolve_model_via_sibling_id`. That is precisely the parallel path this ticket exists to retire.

The depth-0 support lives in two shared helpers, guarded by `path.ancestors.empty?`:

- `resolve_parent`: at depth 0 the parent **is** `provided_data` (today it walks `ancestors`, which is empty for a top-level path and would raise).
- `resolve_model_via_sibling_id`: at depth 0 the sibling `<field>_id` is another **top-level root** (found among `internal_field_configs`), not a child of `leaf_parent_node`.

### Not user-breaking

Unlike PRO-2903 (which changed subfield parent-materialization semantics — user-observable through the parent's own reader), this change is **not** user-breaking. There is no "parent" to materialize at depth 0: a top-level field is its own root. Top-level readers still return the same transformed values — via the read path instead of write-back. `inputs` still forwards transformed values. Outbound copy-forward still forwards the resolved value.

Two marginal refinements carry over from PRO-2903's read-path move and are documented, not silently accepted:

- A top-level `preprocess:` with a **side-effect**, **no validators**, and **never read by user code** no longer fires eagerly (nothing triggers the read). Identical to how PRO-2889/PRO-2903 already treat such a subfield, and an anti-pattern regardless (a field whose only effect is an unread preprocess side-effect).
- Inter-field ordering: a `preprocess:`/`default:` proc that reads *another* field now triggers that field's full read-path resolution (`coerce → preprocess → default`) rather than observing a mid-global-pass value. Write-back ran all coercion, then all preprocess, then all defaults across fields; the read path resolves each field's full chain independently and lazily. Same trade the subfield read path already makes.

## Consumer audit

Every remaining raw-`provided_data` consumer, and its disposition once write-back is gone:

- **Context facade top-level readers** (`InternalContext`, `facade.rb`) — the reroute. The plain reader calls `resolve_value(action, config)` when the field has a config; a field with no config (implicitly-allowed) keeps the raw `_context_data_source[field]` read. The model reader calls `resolve_model_value`. `_define_field_reader` (the action-class reader) is unchanged — it delegates through the facade.
- **`inputs`** (splat-forwarding to nested actions) — **fixed automatically.** It reads `internal_context.public_send(field)`, i.e. the rerouted facade reader, so it forwards **transformed** values. Asserted explicitly: a nested action receiving `**inputs` sees the parent's coerced/preprocessed/defaulted values, not the caller's originals.
- **Inbound validation** (`Validation::Fields#read_attribute_for_validation`) — **fixed automatically, and this is the crux.** A top-level field validates against the facade with `permit_method_call: true`, which *dispatches the facade reader*. Rerouting the reader means validation reads the resolved value through the same seam — it can never validate raw while readers return transformed.
- **`<field>_id` reader** (`contract.rb`, `_define_model_id_reader` → `provided_data[id_key]`) — reroute the raw-id read to resolve `<field>_id` through the read path, so a defaulted/preprocessed id is visible.
- **Model-consistency** (`Executor#_model_consistency_mismatches`, top-level branch reading `@context.provided_data`) — read the resolved record and resolved id (via the readers / seam), so the check agrees with what validation and readers see. The `_id_default_would_conflict_with_present_record?` / `_sibling_model_route_for_id` guards existed only to keep write-back from fabricating a mismatch by materializing a defaulted id atop a present record; with nothing written back they are deleted (a defaulted id that resolves a record is handled value-level by `resolve_model_via_sibling_id`, and a present record is authoritative on read).
- **Outbound copy-forward** (`Executor#apply_defaults!(:outbound)`, `executor.rb:723`) — forward the **resolved** inbound value (`internal_context.public_send(field)`) rather than raw `provided_data[field]`, preserving what write-back forwards today for a field that is both `expects` and `exposes`.
- **Strand diagnostic** (`Executor#_stranded_ancestor_path`, reads `provided_data[root]`) — resolve the root through the seam so the "which nested hop is nil" diagnostic agrees with runtime resolution.
- **Async serialization** — **confirmed no-op.** `call_async(**kwargs)` serializes the raw caller kwargs and the worker re-runs the full pipeline at perform through readers/`resolve_value`. It never touched `provided_data` or write-back.
- **Facet prep** (`Executor#prepare_inbound_for_facets!`, `#resolve_inbound_facets`) — today calls the three write-back passes to materialize transformed values before out-of-band facet resolution. With those passes gone, it resolves lazily on read exactly as `model:` readers already do there; the explicit pre-materialization calls are removed.
- **Auto-logging** (before/after) — **unaffected.** `log_before` ("About to execute with: …") fires in `with_logging`, *outside* `with_contract`, so it already shows raw inputs today; the after-log shows outputs. Neither changes.

### Logging / exception-report inputs show RAW (decision)

`execution_context[:inputs]` (exception reports, handler context) and `inputs_for_logging` read `__combined_data` (raw `provided_data`, sliced + sensitive-filtered), not through readers. Today write-back has already mutated `provided_data` by exception time, so these show **transformed** scalars — while the pre-contract before-log shows **raw**. That is an existing raw-vs-transformed divergence for the same call.

**Decision: these show raw caller input.** No reroute. Rationale: `execution_context[:inputs]` means "what the action was called with," matching the before-log's own "About to execute with:" framing; leaving it raw *removes* the before-log/exception-report divergence rather than preserving it; and it keeps `provided_data` pristine, which is the invariant. The transformed values remain available via readers/`inputs` for any consumer that wants them. The only delta: an exception report for an action with declared transforms now shows the raw invocation args rather than the post-transform value — the more useful anchor for "why did this call fail" anyway.

`sensitive:` redaction is **unaffected**. It lives entirely in `_context_slice`'s `filter.filter(sliced)` (plus `_mask_unfilterable_shapes` for shape members, PRO-2911); both key off field/member **names**, not value provenance, and run over the slice regardless of whether its values are raw or transformed. A `sensitive: true` field's raw value is still redacted. No sensitive behavior was ever tied to write-back (which only ever applied `coerce:`/`preprocess:`/`default:`).

## Approach — commits in one PR

The hazard is regressing the most fundamental input read while re-homing it. The flip and the delete **must be atomic**: while write-back still mutates `provided_data`, rerouting a reader to re-read and re-transform that same mutated data would double-apply `preprocess:` (which is not idempotent — unlike coerce-or-leave and the nil-guarded default). So the sequence is "add the seam capability, prove it in isolation; then flip-and-delete in one commit."

### Commit 1 — teach the seam depth-0 (purely additive, no reroute)

Add the depth-0 capability without wiring any consumer to it, so nothing double-applies and the change is provable in isolation (call `resolve_value` on a top-level config directly, against a pre-pipeline action, and assert it produces the write-back value):

- `resolve_parent`: depth-0 branch returning `provided_data` (via a clean internal accessor on the action for its `@__context.provided_data`; today it walks `ancestors`, empty at depth 0, and would raise).
- `resolve_value`: verified to work for a top-level config once `resolve_parent` handles depth 0 (leaf-extract from `provided_data`, `coerce → preprocess → default`). Preprocess-on-nil: top-level parent is `provided_data` (non-nil), so preprocess runs even on an absent/nil field — matching write-back's unconditional top-level preprocess.
- Extract a shared `resolve_model_value(action, config, options)` (parent → record → sibling-id rescue → default fallback) and add the depth-0 branch to `resolve_model_via_sibling_id` (sibling `<field>_id` is a top-level root).

Nothing reads through the new capability yet; write-back still owns every read. Suite green.

### Commit 2 — flip the facade + consumers onto the seam AND delete write-back (atomic)

- Reroute `InternalContext`'s plain reader (config → `resolve_value`; no config → raw `_context_data_source[field]`) and model reader (`resolve_model_value`); reroute the `<field>_id` reader to resolve through the read path.
- In the same commit, delete `apply_inbound_coercion!`, `apply_inbound_preprocessing!`, `apply_inbound_defaults!`, and the depth-0 helpers now unused (`_current_value_at`, `_write_value_at!`, `_sibling_model_route_for_id`, `_id_default_would_conflict_with_present_record?`). Remove the `apply_defaults!(:inbound)` dispatch and the pre-materialization calls in `prepare_inbound_for_facets!`.
- Reroute the remaining raw-`provided_data` consumers to the resolved values: model-consistency (top-level), the outbound copy-forward, and the strand diagnostic.
- `_clear_pre_pipeline_memos!` already clears `@__resolve_value_cache`; confirm top-level model-reader memos (on the facade singleton) remain uncleared so a top-level finder is not re-run (pre-existing behavior).

At the end of commit 2: one resolution path for top-level and subfields, the write-back passes gone, `provided_data` pristine. Because the reroute and the delete land together, no read is ever served by both mechanisms.

## Testing

- **Mutation-free acceptance test (the wedge):** after a call whose top-level field declares `coerce:`/`preprocess:`/`default:`, `@context.provided_data` still holds the **raw** caller value byte-for-byte, while the reader returns the transformed value. A caller-supplied settable object referenced by an input is unchanged after the call.
- Full regression of the existing top-level `coerce:`/`preprocess:`/`default:` suite through the read path — happy path, blank/nil/absent edges, ordering (`coerce → preprocess → default`), `coerce_input_types` (whole-action), and the "could not be coerced" message parity.
- **`inputs` forwards transformed (not raw) values:** a nested action receiving `**inputs` sees the parent's resolved defaults/preprocessing/coercion, not the caller's originals.
- Model-consistency continues to hold: a record + `<field>_id` that disagree still raise; a defaulted id that resolves a record does not fabricate a mismatch; a present record is authoritative.
- Top-level `model:` with a sibling `<field>_id` default still resolves the record via the read path (the depth-0 `resolve_model_via_sibling_id`).
- Async: enqueue/perform round-trips the raw kwargs and re-runs the pipeline at perform (unchanged).
- Exception-report `execution_context[:inputs]` shows the **raw** caller input for a field with declared transforms (the logging decision).
- Non-Rails (`spec/`) and Rails (`spec_rails/dummy_app/`) both, per AGENTS.md — model behavior is exercised in both.

## Docs / CHANGELOG

- CHANGELOG entry (a `FEAT`/refinement, not `[BREAKING]`): top-level `coerce:`/`preprocess:`/`default:` now resolve on the read path; axn no longer mutates `provided_data` during inbound validation. Note the two marginal refinements (unread validator-less `preprocess:` side-effect; inter-field read ordering) and the exception-report-shows-raw-inputs change.
- Update executor/facade comments that frame top-level resolution as write-back ("a top-level field is its own root, so its result always writes", "top-level reader memos are deliberately NOT cleared", the write-back pass headers).
- Remove any reference framing write-back as the top-level resolution mechanism now that the read path is unified.
