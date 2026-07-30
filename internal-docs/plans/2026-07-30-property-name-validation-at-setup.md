# Property-Name Validation at App Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the two property-name rules (collision, renderability) from firing on every `expects`/`exposes` call to firing once per class when the contract's JSON projection is first demanded — and guarantee that, for tool axns, "first demanded" happens during app setup rather than on a user's tool call.

**Architecture:** The rules already derive from reflection's emitted schema, so they belong with reflection rather than inline in the contract DSL. Extract them to an internal `Axn::Reflection::PropertyNames`, make the trigger lazy and memoized per class, and drive it at boot from a Rails `after_initialize`/`to_prepare` hook plus an explicit entry point for non-Rails apps.

**Tech Stack:** Ruby, RSpec, RuboCop. No new dependencies.

**Ticket:** [PRO-2995](https://linear.app/teamshares/issue/PRO-2995/axn-reject-exposure-names-that-canonicalize-to-one-json-property-at)
**Prior plan:** `internal-docs/plans/2026-07-29-declaration-time-property-name-collisions.md`

## Why this changes the promise deliberately

Nothing but a JSON projection can be harmed by a colliding or unrenderable property name. `Axn::Result` defines no `to_h`, `as_json`, or `to_json`; the only surfaces are `input_schema`/`output_schema` and `Axn::Extensions::Serialization.render`, which `lib/axn/reflection.rb:15` names as the gem-facing entry points. For an axn nothing ever projects, two names that canonicalize alike remain two distinct fields with distinct readers and validations, and nothing breaks. So the honest promise is **"raises before anything can consume it — at app setup for tools"**, not "raises when the class is defined."

Gating on tool membership at declaration is not possible: `tool` can be declared after `expects` (verified), and directory grants resolve later in the registry. Laziness gates on projection instead, which is the same set by construction.

The cost motivation is secondary but real. Cost is the product of declaration calls and schema size, because the current design re-derives per call:

| Contract | Now |
| --- | --- |
| 30 plain fields, one `expects` call | 2.6 ms |
| 30 plain fields, 30 calls | 5.7 ms |
| 60 plain fields, 60 calls | 15.7 ms |
| 3 fields, each a 10-member shape | 2.3 ms |
| 30 fields, each an 8-member shape | 39.7 ms |

One build per class removes the call-count factor entirely.

## Global Constraints

- **Behavior of the rules does not change.** Same errors, same messages, same legal-merge semantics, same six merge controls. Only *when* they run and *where* they live.
- **The `exposes` field-name renderability check stays in `Core::Contract`, eagerly.** That name reaches the serialized body via `Values.serialize_exposed` (`values.rb:130`) regardless of what any schema emits, so it is not projection-gated.
- **Memoize per class, and invalidate on further declaration.** A class whose contract grows after a projection must re-validate on the next projection.
- **`Axn::Reflection::PropertyNames` is internal.** Not an adapter surface; `AGENTS.md`'s namespace policy governs.
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- Never assert `Hash#inspect` text in a spec (Ruby 3.4 changed its spacing; CI runs 3.2/3.3/3.4).
- Non-UTF-8 symbol fixtures must be `ASCII-8BIT`; spec files are frozen-string-literal, so `.dup` before `force_encoding`.
- RuboCop maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60.
- Suites: `bundle exec rspec`; `bundle exec rubocop`; and from inside the dummy app, `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../`.
- The 123-row hostile harness must stay green at every step, and every step reports its A/B.

---

### Task 1: Extract to `Axn::Reflection::PropertyNames` — pure move

No behavior change. `contract.rb` is 1,994 lines and the claim walker, both rules, and their message builders are inline in it.

**Files:**
- Create: `lib/axn/reflection/property_names.rb`
- Modify: `lib/axn/reflection.rb` (require), `lib/axn/core/contract.rb` (delegate), `lib/axn/core/contract_for_subfields.rb` if it calls in
- Test: existing suite plus the harness are the oracle; add one spec asserting the module's public surface

- [x] **Step 1: Inventory what moves**

List every method involved in the two rules and their reporting, and every caller. The `exposes` field-name renderability check does **not** move. Put the inventory in the report so the next step is mechanical.

- [x] **Step 2: Move, delegating from `Core::Contract`**

Keep the call sites in `expects`/`exposes` for now — this task only relocates the implementation. `Core::Contract` calls `Axn::Reflection::PropertyNames`.

- [x] **Step 3: Verify pure**

`bundle exec rspec`, `bundle exec rubocop`, the harness, and the dummy app. Every one must be green with **no spec edits** — that is the definition of pure here. If a spec needs changing, the move was not pure; say so rather than editing it.

- [x] **Step 4: Commit**

```bash
git commit -m "PRO-2995: property-name rules move to the layer whose output they judge"
```

---

### Task 2: Make the trigger lazy and memoized

**Files:**
- Modify: `lib/axn/reflection/property_names.rb` (entry point + memo), `lib/axn/core/contract.rb` (drop the per-declaration calls, mark dirty), `lib/axn/core/schema_reflection.rb` (validate before returning a schema), `lib/axn/extensions/serialization.rb` (validate before rendering)
- Modify: `spec/axn/core/validations/property_name_collision_spec.rb` and any sibling asserting a declaration-time raise

- [x] **Step 1: Decide and document the trigger set**

Validation must run before any of: `input_schema`, `output_schema`, `Extensions::Serialization.render`. Check whether any other public path exposes a projection; if one exists, it is a trigger too. Record the set in the module's doc comment — it is the contract.

- [x] **Step 2: Memo and invalidation**

Memoize per class. Every declaration marks the class dirty so the next projection re-validates. A subclass that adds declarations must not inherit a clean memo — verify inheritance explicitly, since the contract is copy-on-write.

- [x] **Step 3: Migrate the specs**

87 of 120 examples in `property_name_collision_spec.rb` assert `expect { build_axn { … } }.to raise_error`. They become "raises when the projection is first demanded." Prefer a helper that declares then projects, so each example still reads as one behavior. **Keep at least one example per rule asserting the error class and full message**, so the migration cannot quietly weaken what is checked.

- [x] **Step 4: Prove the gate**

Add specs: an axn that never projects declares cleanly despite a colliding contract; the same axn raises on first `input_schema`; and the raise repeats on a second call (a memo must not swallow it).

- [x] **Step 5: Re-measure**

Report the five contracts from the table above. The call-count factor should be gone.

- [x] **Step 6: Commit**

---

### Task 3: Trigger at app setup

**Files:**
- Modify: `lib/axn/rails/engine.rb` (hooks), `lib/axn/tools/registry.rb` (expose loading + enumeration for validation), `lib/axn.rb` (public entry point)

- [x] **Step 1: Expose tool-dir loading independent of `tools_for`**

`Registry.ensure_loaded!` currently runs only from `tools_for`. Make it callable on its own, and add a way to enumerate registered tool classes for validation.

- [x] **Step 2: `Axn.validate_tool_contracts!`**

Loads tool dirs, projects each tool axn once, and raises on the first invalid contract. This is the non-Rails entry point and what the Rails hooks call.

- [x] **Step 3: Rails hooks — ordering matters**

Use `config.after_initialize`, **not** an initializer after `load_config_initializers`: `registry.rb:112-117` documents that Rails' eager-load phase runs late in boot, so an earlier hook would force tool classes to load before the app's own initializers have run. Also register `config.to_prepare` so a dev reload re-validates — Zeitwerk unloads on code change, and a one-shot hook would validate only the first boot.

- [x] **Step 4: Document the coverage hole**

Under Rails, `eager_load_dir` loads a directory as one unit, so one raising file aborts the rest of that directory (warn-logged) — validation for those siblings silently does not happen. An axn made a tool by the `tool` DSL in a file outside the tool directories is likewise not loaded at boot in dev, and falls back to first projection. Both go in the module doc and the docs page. Do not imply full coverage.

- [x] **Step 5: Specs, including the dummy app**

The Rails path needs coverage in `spec_rails` — a dummy-app tool axn with a colliding contract must fail at boot. Verify the hook fires and the message names the offending class.

- [x] **Step 6: Commit**

---

### Task 4: Documentation

**Files:**
- Create: `docs/recipes/running-without-rails.md`
- Modify: `docs/.vitepress/config.mts` (nav), `CHANGELOG.md`, and whichever reference page states the declaration-time promise

- [x] **Step 1: The non-Rails recipe**

The Rails-conditional behaviors, verified by grep — build the page from these rather than from imagination, and check each against the code:

| Behavior | Rails | Without Rails |
| --- | --- | --- |
| Tool-contract validation at setup | `after_initialize` + `to_prepare` | call `Axn.validate_tool_contracts!` yourself |
| `app/actions` on the autoload path | engine initializer (`lib/axn/rails/engine.rb`) | require your action files yourself |
| Tool-dir loading | Zeitwerk `eager_load_dir`, per directory | `require` per file (`registry.rb:111`) |
| Tool roots resolved relative to | `Rails.root` (`registry.rb:346`) | supply absolute paths |
| `on_success` deferred to after commit | `ActiveRecord.after_all_transactions_commit` (`executor.rb:959`) | runs inline; no commit hook |
| `use :transaction` | works | raises `NotImplementedError` (`strategies/transaction.rb:9`) |
| `model:` fields | ActiveRecord lookup | requires an AR-like `find_by` |
| Generators | `rails g axn` | not available |
| Vernier profile output path | `Rails.root` | cwd (`extras/strategies/vernier.rb:99`) |

Frame it as "axn runs standalone; these are the seams you own yourself," and link the existing non-Rails notes in `docs/advanced/mountable.md`, `docs/usage/writing.md`, and `docs/reference/class.md` rather than restating them.

- [x] **Step 2: Correct the promise wording**

Anywhere the docs or CHANGELOG say these rules raise "at declaration" or "when the class is defined", change it to what now holds: raised when the contract's JSON projection is first built, and at app setup for tool axns. Leave the `exposes` field-name rule described as declaration-time, because it is.

- [x] **Step 3: Verify**

`bundle exec rspec`, `bundle exec rubocop`, the dummy app, and the docs link check if it can be run locally.

- [x] **Step 4: Commit**
