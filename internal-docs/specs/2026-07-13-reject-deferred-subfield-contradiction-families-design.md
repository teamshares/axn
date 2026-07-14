# Reject the Deferred Subfield Contradiction Families at Declaration — Design

**Date:** 2026-07-13
**Ticket:** [PRO-2889](https://linear.app/teamshares/issue/PRO-2889/axn-reject-the-three-deferred-subfield-contradiction-families-at)
**Builds on:** PRO-2877 (PR #153, shipped family 4), PRO-2883 (PR #159, canonical SubfieldTree), PRO-2886 (PR #162, per-segment Extract — **must merge first**)

## Context: the ticket's premises, re-verified

PRO-2877 pulled families 1–3 because each detector re-derived runtime semantics with parallel logic and kept missing rescue paths. The ticket prescribes reusing the canonical tree's derivations instead. Runtime probes on this branch (post-PRO-2883) show the ground truth has moved since the ticket was written, which reshapes two of the three families:

- **Family 3's original hazard is gone.** The executor's chain-aware write path refuses to synthesize `{}` under a `model:` node (`Executor#_synthesizable_node?`), so a subfield default under a nil-tolerant model parent no longer poisons `ModelValidator` — it is *silently skipped*, and the call fails on the stranded (presence-required) subfield instead. Verified: `expects :company, model: X, allow_nil: true` + `expects :name, on: :company, default: "x"` → `call()` fails `"Name can't be blank"`; `call(company_id: 7)` succeeds; a defaulted explicit `company_id` sibling **does** rescue omission now (the ticket's contrary claim reflects pre-2883 truth); a record-supplying own default rescues. Family 3 is family 1 routed through model semantics.
- **Family 2's TypeError is gone.** PRO-2883's malformed-input doctrine settles a failed dig as absent (`extract_or_nil`), and PR #162 resolves dotted paths segment-by-segment with per-segment method dispatch — erasing the reader-vs-dig spelling asymmetry the ticket centers on (`"items.count"` ≡ `:count on :items`, per that PR's parity spec). What remains statically detectable is a traversal segment **no admissible declared branch can answer**.
- **Family 1 is confirmed as described**, including the rescue tail: a subfield default materializes a fully-object-shaped chain (even over an explicit `payload: nil`) and rescues omission.

Additionally probed, motivating the capability piece below — today the *same* declaration `expects :name, on: :company, default: "x"` behaves three different ways: omitted parent → default dead, call fails; id-resolved record with nil attribute → default dead, call fails; caller-supplied record with nil attribute → the default is written **onto the caller's record via its setter** (an unsaved attribute mutation on an AR instance).

The pulled PR #153 detector/spec code was recovered for reference (commit map: family 1 added `54fea91d5`/pulled `3cdefd2bc`; family 2 `0bd84481c`/`98d05645d`; family 3 `ab297934c`/`a67440c70`; PR head fetched as `origin/pr-153`). It is reference, not gospel — several of its learned rules assert now-wrong behavior.

## Goals

- **Value-level subfield defaults (new capability):** a declared `default:` guarantees the subfield's *resolved value* — reader and validation both — is never nil-by-omission, regardless of whether the wire write-back could apply it. Stop mutating caller-supplied objects with defaults.
- **Families 1+3, one detector:** reject at declaration a declared nil-tolerance (`allow_nil:`/`optional:`/`allow_blank:`/`presence: false`) whose omission *unconditionally fails* — judged by the canonical omittability derivation in a new optimistic **satisfiability mode**, never a parallel re-derivation.
- **Family 2:** reject at declaration a subfield whose resolution path contains a segment no admissible declared branch can answer (post-#162 semantics), regardless of the subfield's own requiredness (dead machinery, per the shipped family-4 precedent).
- Reflection co-updates so schema and runtime move together; re-add the pulled spec coverage adapted to current truth.

## Non-goals

- Conditional requiredness ("required iff parent present") — **decided: reject outright.** PRO-2881 can later *legalize* the family-1 spelling with real conditional semantics, a non-breaking relaxation; the reverse order would be a breaking re-illegalization.
- `preprocess:` semantics (still never synthesizes ancestors, still writes via the setter branch — PRO-2857 unchanged).
- Deep ambient nesting (PRO-2844/2845), outbound subfields, contradictory-type detection at a single node (`type: String` route + `type: Hash` route).

## Part 1 — Value-level subfield defaults

**Semantics.** The write-back pass (`apply_inbound_defaults!`) stays exactly as is for materializable chains — it is what makes a deep default materialize `payload: {meta: {id: 42}}`, satisfy the parent's own presence, and keep wire data coherent for model resolution. New rule at the shared resolution seam: when a subfield's resolved value is nil after the write pass — chain refused (model/non-object parent), parent record's attribute nil, malformed parent — the declared `default:` supplies the value at read time. No wire data is written; the parent's own value (nil record, nil array) is untouched, so a nil-tolerant parent stays genuinely nil.

**Seam.** One helper in `ContractForSubfields` (alongside `resolve_parent`): leaf-extract from the canonically-resolved parent, then default fallback when nil and `config.applied_default?`. Consumers:

- The generated subfield readers (plain and `model:` — a nil-resolving model subfield falls back to a record-supplying default, which `ModelValidator` then validates normally). Memoization means a Proc default resolves once per instance. The `<field>_id` companion reader is untouched (its value is wire data; a defaulted record has no wire id, matching the top-level precedent).
- `Validation::Fields#read_attribute_for_validation` extends its existing model-route pattern to read *every* subfield through the action's reader when one exists — "the reader is the field's value" becomes the doctrine, and validation sees exactly what user code sees. Dotted-name configs (no reader) resolve through the helper directly; they are read only by validation, so a Proc default still resolves once.
- Proc defaults resolve via the shared default-resolution path (`instance_exec`, `DefaultAssignmentError` wrapping) extracted from `Executor#_resolve_default` rather than duplicated.

**Mutation removal.** `default:` write-back no longer takes the object-setter branch (`_cow_write`'s `respond_to?("#{seg}=")` arm) — a caller's record is never mutated by a declared default. The read-time fallback makes the write redundant. `preprocess:` writes are unchanged. `[BREAKING]` CHANGELOG entry: code relying on the mutated attribute after `call` must read the axn's reader instead.

**Observable consequences (intended):** `expects :company, model: X, allow_nil: true` + defaulted `:name` subfield → `call()` succeeds with `name == "x"` and `company` nil; id-resolved records with nil attributes get the default; `expects :items, type: Array, allow_nil: true` + defaulted `:count` subfield becomes satisfiable-on-omission. Exception-context/inspection views of `provided_data` show what the caller sent (read-time defaults are not injected into wire data); facet resolution reads via readers and so sees defaults.

**Reflection co-updates (same commit):** with defaults applying at any depth under any parent, `node_omittable_without_synthesis?`'s model-subtree carve-out is deleted — `apply_model_id_requiredness!`'s children check reduces to the ordinary annotation-based omittability (`node_optional?`), so a defaulted descendant no longer forces `company_id` required. The synthesis-aware reasoning that *survives* is exactly the parent-presence analysis: subtree defaults still rescue a *parent's own* presence only via `{}` materialization (object chains only — `field_optional?`'s third branch and `required_child?`'s shape-hazard clause are unchanged). `usable_default?` stays strict (Proc-excluded) for schema purposes.

## Part 2 — Satisfiability mode on the canonical derivation

The omittability predicates (`usable_default?`, `node_optional?`, `field_optional?`, `subtree_has_usable_subfield_default?`, `derive_annotations`/`annotate_node!`) gain a `satisfiability:` flag (default false = today's strict schema mode). The full semantic delta in satisfiability mode:

- The governing principle: **unknowable-at-declaration counts as satisfiable** — rejection is reserved for *provably* dead declarations, so strict mode resolves uncertainty toward required (schema safe-direction) and satisfiability mode resolves it toward satisfiable. Today the only unknowable is a **Proc default** (`usable_default?` returns true for a Proc: it applies at runtime; a raising Proc is unknowable); when PRO-2881 adds dynamic/conditional requiredness (dynamic `optional:`, `if:`/`unless:` on validations), those signals slot into the same seam without touching the detector.
- Nothing else changes. The blank-default rule is runtime-true in both modes (a blank default applies but an active presence validator rejects it — not a rescue); after Part 1, the "default rescues its own node at any depth" rule is runtime-true in both modes.

The detector derives satisfiability annotations fresh on the candidate tree at declaration time; the per-class cache only ever holds strict annotations, so schema emission is untouched.

## Part 3 — Families 1+3: the dead-nil-tolerance detector

`Axn::Reflection::SubfieldContradictions` returns as a *thin* module: `_expects_subfields` builds a candidate tree (`SubfieldTree.build(internal_field_configs, subfield_configs + prospective)`) pre-commit — alongside the existing validate-before-commit checks, leaving the class untouched on raise — derives satisfiability annotations, and walks once.

**The rule.** For each explicit config `c` at node `N` where `nil_accepted?(c)` (a **statically-declared** tolerance — bare `expects` injects `presence: true`, so nil-acceptance only arises from explicit flags): reject when `N` is not omittable in satisfiability mode. Keying on static declarations is what makes this compose with PRO-2881: a future dynamic/conditional requiredness signal is outside the reject set by construction (its whole point is that omission *might* pass), and once that spelling exists the rejection message gains it as a named fix — the migration path for family-1 shapes with genuinely conditional intent. Top-level fields judge via `field_optional?`; model fields via the `apply_model_id_requiredness!`-analog (own omittability + all children omittable + the defaulted-explicit-id-sibling rescue); subfield nodes via `node_optional?`. Every rescue the runtime honors is honored here *by construction* — same predicates, optimistic flag: own defaults (Proc/record-supplying included), read-time descendant defaults, `{}`-materialization on object chains, blank-rejected defaults correctly not counted, id-sibling defaults for models.

**Message shape** (each names both declarations and the fixes): `":payload is declared allow_nil:, but :id (on "payload.meta") is required and nothing rescues an omitted :payload — drop allow_nil: on :payload, mark :id optional:, or give :id a default:"`. The model flavor mentions the model-specific fixes (a record-supplying default on the model field, a defaulted `<field>_id` sibling).

**Order-dependence footguns (accepted, documented in the message):** a rescue that arrives in a *later* declaration — a merged-route default (`expects "meta.id", on: :payload, default: 5` declared after the stranded `expects :id, on: "payload.meta"`) or a defaulted top-level `<field>_id` sibling declared after the model's subfield — cannot un-raise the earlier rejection. The error text says to declare the rescuing default first. Inherent to fail-at-declaration for cross-declaration analysis; both spellings are contrived and the fix is a line swap.

## Part 4 — Family 2: the unanswerable-segment detector

**The rule (post-#162 runtime mirror).** A subfield's value resolution digs/reads specific segments: the `on:`-path hops after the deepest reader-bearing ancestor (mirroring `resolve_parent`'s recipe — shared, not re-derived), then the (possibly dotted) field-name segments off the resolved parent. For each such hop, the position's enforced declarations are its explicit node configs plus any colliding `shape:` members (located via `Schema.shape_members_at`, carrying merged members through implicit nodes exactly as the drop pass does). A position **answers** a segment when, for every enforced config, *some* admissible branch answers it: Hash/`:params`/untyped and unknown classes answer any key (optimistic); a plain scalar branch (the `TYPE_MAP` scalars, `Array`, `:boolean`/`:uuid`/singleton booleans) answers iff `method_defined?(segment)` (pure reflection, no user code); a `model:` route answers unconditionally (AR defines attribute methods lazily, so `method_defined?` on the model class is untrustworthy — optimistic). If *some* enforced config has *no* answering branch, every contract-valid value at that position leaves the subfield permanently absent → reject.

This keeps the ticket's required negatives legal by construction: `:count` on an `Array` member/subfield, `:length` on a `String` member (`method_defined?` true), and any path through model parents or unknown classes.

**Rejected regardless of the subfield's own `optional:`/`default:`** — an unanswerable path is dead machinery even when the contract stays satisfiable, matching the shipped family-4 precedent (and with a default it degenerates to a constant field). Family 2 is checked before families 1+3 so the more specific message wins when both fire.

**Message shape:** `subfield "bar.baz" (on :payload) can never resolve: segment "baz" reads through \`field :bar, type: String\`, and String does not respond to #baz — make :bar an object-shaped member, or drop the subfield`.

**Relation to the drop pass:** unchanged and orthogonal — `dropped_deep_subfields` remains the schema-representability analysis (model/Array/mixed-union parents stay legal, runtime-resolvable, and dropped from the schema); family 2 rejects the strictly-narrower runtime-unresolvable set.

## Testing

TDD throughout; `spec/` plus `spec_rails/dummy_app` mirrors for everything `model:`-flavored (AR record fallback, no-mutation regression, lazy attribute methods vs `method_defined?`).

- **Value-level defaults runtime-truth matrix:** {omitted parent, explicit nil, id-resolved record, caller-supplied record, present-with-nil-attr, malformed parent} × {literal default, Proc default, record-supplying default, blank default, `default: false` boolean} — reader value, validation outcome, and `provided_data` non-pollution asserted per cell; the caller's-record-not-mutated regression test.
- **Detector positives per family**, each spelling that reaches it (dotted `on:`, dotted name, subfield-of-subfield, top-level vs intermediate nil-tolerant ancestor; model root vs model subfield), asserting messages name both declarations.
- **Detector negatives** — the rescue tail as living specs: Proc default, record-supplying own default, defaulted-id-sibling-declared-first, deep default materializing an object chain, blank-default-*with*-`presence: false` (rescues) vs blank-default-with-presence (doesn't → reject), merged-route default declared first, `:count`/`:length` reader-leafs, unknown-class and model-parent paths.
- **Schema parity:** `input_schema` matches runtime for the newly-legal contracts (defaulted-under-model → `company_id` not required; the collapsed `node_omittable_without_synthesis?` cases), and is unchanged for surviving legal contracts.
- **Re-added PR #153 coverage** adapted to current truth (the recovered specs asserting `{}`-poisoning or id-sibling-non-rescue are updated, not resurrected).

## Compatibility & CHANGELOG

- `[FEAT]` value-level subfield defaults (the three-way path-dependence example, and that reader + validation now agree).
- `[BREAKING]` `default:` no longer mutates a caller-supplied parent object (read the axn's reader instead).
- `[BREAKING]` one entry per rejection family: previously-loading contracts now raise `ArgumentError` at class definition, with the old runtime failure mode and the fix spelled out.
- Consumer sweep before merge: grep os-app, axn-mcp, axn-ruby_llm, data_shifter, slack_sender for declarations hitting the new rejections or relying on default-mutation — inventorying the family-1 shape specifically (contracts with conditional intent, e.g. the spec_rails dummy-app `expects :data, optional: true` + `expects :user, model:, on: :data` that PRO-2881's ticket cites; these will need in-PR fixes now and can move to the conditional spelling when PRO-2881 lands).

## Sequencing

PR #162 (PRO-2886) merges first; this branch rebases onto main. Commits, each with its spec block:

1. Value-level defaults + mutation removal + reflection co-updates (capability first, so detectors encode the new runtime truth from day one).
2. `satisfiability:` mode on the Schema predicates (pure parameterization, no behavior change at default).
3. Families 1+3 detector + re-added family-1/3 coverage.
4. Family 2 detector + re-added family-2 coverage.
