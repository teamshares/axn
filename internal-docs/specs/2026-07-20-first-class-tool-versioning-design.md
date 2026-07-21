# First-class tool versioning, separate from tool_name (PRO-2955)

Linear: https://linear.app/teamshares/issue/PRO-2955/axn-first-class-tool-versioning-separate-from-tool-name

## Motivation

`tool_name` is an Axn's identity across every serving adapter (`axn-mcp`, `axn-ruby_llm`, `axn-openapi`). The registry treats it as a unique per-adapter identity — `Axn::Tools::Registry._assert_unique_tool_names!` raises on a collision — so two revisions of one logical tool cannot coexist. A breaking contract change therefore forces either breaking clients (no versioning) or leaking the version into the name (`approve_loan` → `approve_loan_v2`), which makes every adapter see a noisy distinct tool with no notion of "the latest" and no path-based routing.

This ticket adds `version` as a **first-class core tool attribute, a sibling of `tool_name` — never part of it.** Coexisting versions group under one logical `tool_name`; the version is carried separately; each adapter projects it as fits its consumer. The locked principle from PRO-2936 holds: if HTTP/wire versioning ever surfaces it lives in the path, never as a scheme imposed on the cross-adapter `tool_name`.

This PR is **core only** — the DSL, the registry identity, the enumeration surface, and the docs for the filesystem convention. The adapters that actually *project* version (`axn-openapi` path-routing, `axn-mcp`/`axn-ruby_llm` latest-only) are downstream follow-ups.

## Proposal

A new core module `Axn::Core::Versioning` (sibling of `Axn::Core::SemanticHints`) adds a `version` DSL:

```ruby
class ApproveLoan
  include Axn
  version 2, default: true
  # …
end
```

- `version N` sets the tool's contract version. Absent ⇒ version 1 and the default.
- `default: true` blesses this version as the movable **stable pin**.
- The registry's identity becomes `(tool_name, version)`. `_assert_unique_tool_names!` relaxes to unique-per-`(tool_name, version)`.
- `tools_for(adapter)` returns **latest-per-`tool_name`** by default — backward-compatible, since today's tools are all unversioned (latest-of-one is itself).
- `tools_for(adapter, all_versions: true)` enumerates every version.
- `versions_for(adapter, tool_name)` returns the resolved version group (`.all` / `.latest` / `.default`).

## Concepts: policy vs. designation

The word "default" conflates two separable things; the spec keeps them apart.

- **The selection *policy*** — "which version does an adapter serve when the caller names none?" — is **per-adapter** and lives in each adapter (downstream): LLM adapters serve `latest`; the openapi bare path serves the stable pin. This PR ships no policy.
- **The core-exposed *designations*** those policies consume are what this PR provides:
  - **`latest`** = computed `max(version)` in a group. Not declared. What MCP/ruby_llm read.
  - **`default`** = a single author-blessed stable pin: the earliest version unless `default: true` moves it. What the openapi bare path reads.

`default` is therefore **not** "the version everyone serves" — MCP never consults it, it reads `latest`. The MCP-latest vs HTTP-pinned asymmetry *is* the per-adapter decision, honored by exposing two designations and letting each adapter pick. `default` stays a single core value (one "blessed stable version" per tool, traveling with the tool definition rather than living in adapter config); a per-adapter `default` override is a clean later addition if ever motivated, and is explicitly out of scope here.

## Decisions

### DSL shape: `default:` is a keyword on `version`

`version 2, default: true`. A bare tool (no `version`) is version 1 and the default; standalone `default: true` on version 1 is a harmless no-op (it is already default). `version` is single-valued and **core, not per-adapter** — unlike `tool_name`, there is no per-adapter version override. Grouping still keys on `tool_name(adapter)`, so latest/default resolve per-adapter naturally.

### Validation is fail-loud at declaration; group conflicts fail at enumeration

Anything knowable from a single class raises at declaration: `version` must be an `Integer >= 1`; the `::Vn` guards below. Anything requiring the whole group (a duplicate `(tool_name, version)`, two `default: true`) is only knowable once every file is loaded, so it raises during group resolution — the same timing as today's `_assert_unique_tool_names!`. **Gaps between versions are legal** (`v1` + `v3`, no `v2`): versions get retired, and requiring contiguity would only punish deletion.

### `version` shadowing raises at definition time (diverges from `description`)

`include Axn` extends axn's class-method DSLs onto the including class, and Ruby places extended modules *above* the superclass chain in singleton-method lookup — so axn's `version` would silently win over a `.version` a base class already owns (the PRO-2875 shadowing hazard). `description` handles its equivalent collision by **deferring** (skip the extend, debug-log) because its collision is legitimate: an adapter base like `Axn::MCP::Tool < ::MCP::Tool` owns a `description` with transport meaning, and using the base's is the *correct* outcome.

`version` is different and **raises instead**. Axn's `version` means "tool contract version"; an unrelated base `.version` (a gem or protocol version) does not satisfy that meaning, so both silent outcomes are footguns: deferring makes the author's `version 2` no-op against the base method (tool silently stays v1), and clobbering breaks the base's own consumers. At include time (in `Axn::Core::Versioning.included`, mirroring how `Naming` consults `MethodShadowing` for `description`), if `MethodShadowing.externally_defined?(base, :version)` is true, axn raises with an actionable message naming the owning ancestor. This is a deliberate divergence: `description`'s defer is behaviorally correct and load-bearing for real adapter bases; `version` has no such legitimate owner, so a loud, early, fixable error beats a debug line nobody reads. (A `debug` log is effectively invisible; the raise removes it from the path entirely.)

The cost is rigidity — a base that legitimately owns `.version` cannot host axn tools without disambiguating — accepted as a rare, documented tradeoff. If it ever bites a real base we can soften to defer.

### `tool_name` derivation drops a trailing `::Vn` when `version` is declared (option B)

The filesystem convention promotes a flat `approve_loan.rb` (constant `AgentTools::ApproveLoan`, derived `tool_name` `"approve_loan"`) to `approve_loan/{v1,v2}.rb`, whose constants become `AgentTools::ApproveLoan::V1` / `::V2`. Fed through today's derivation those yield `"agent_tools_approve_loan_v1"` / `..._v2` — two *different* names, so the versions would silently fail to group (different names ⇒ no collision raised, just two orphan single-version tools).

So when a class **declares `version`** *and* its final constant segment matches `/\Av\d+\z/i`, `tool_name` derives from the **enclosing** namespace (`AgentTools::ApproveLoan::V2` → `"approve_loan"`). This is scoped to *name* derivation and gated on an explicit `version` declaration — distinct from the *filename→version* derivation the ticket deliberately rejects (`version N` remains the sole source of truth for the number). Explicit `tool name:` / `axn_name` still win ahead of derivation, unchanged.

Gating on the `version` declaration (rather than the name pattern alone) keeps the name segment and the version number consistent — a `::V2` class is genuinely version 2, never "named V2 but secretly version 1" — and makes each file in a promoted folder carry an explicit, self-documenting `version N`.

### Two `::Vn` guards close the derivation footguns

Both fire only on the unambiguous `::Vn` convention, at the earliest point each is knowable:

- **`::V2` present, but declared `version M` with `M != 2`** (`::V2` declaring `version 3`) → raise **at declaration**, inside the `version` DSL call (both the constant name and the declared number are in hand there). Message: align them or rename. Keeps the segment and the number honest, since the segment is what derivation drops.
- **`::Vn` present, no `version` declared** → raise **at enumeration** (during `tool_name` derivation / group resolution). There is no declaration event to hook here — `version` was never called — so this is caught where the derivation would otherwise silently orphan the class (`v1.rb` deriving `..._v1`), the same timing class as the duplicate-`(tool_name, version)` and two-`default:` checks. Message: declare `version N` or rename the constant.

## Behavior

### `Axn::Core::Versioning`

Storage is defined unconditionally in `included`'s `class_eval` (so even a class that fails the shadowing guard would have had the ivars): `class_attribute :_tool_version, instance_accessor: false, default: nil` (`nil` = undeclared ⇒ effective 1 & default) and `:_tool_version_default, default: false`.

The `version` DSL is extended onto the class **only after** the shadowing check passes (the check raises otherwise), so there is no deferral path:

```ruby
def version(value = NOT_SET, default: false)
  return tool_version if value.equal?(NOT_SET)         # sugar reader → effective
  raise ArgumentError, "version must be an Integer >= 1 (got #{value.inspect})" unless value.is_a?(Integer) && value >= 1
  self._tool_version = value
  self._tool_version_default = default
end
```

`tool_version` — the canonical, storage-backed reader — is the sibling of `tool_name` and is what the registry, adapters, and reflection consume. It is **not** in the shadowing path (only the terse `version` DSL is), so enumeration is immune to whether a base owned `.version`:

```ruby
def tool_version
  _tool_version || 1
end
```

The mismatch guard (`::V2` declaring `version 3`) lives in the `version` DSL itself: after setting `_tool_version`, if `self.name`'s final segment matches `/\Av(\d+)\z/i` and the captured number differs from `value`, raise. (An anonymous/unnamed class has no constant segment, so the check is simply skipped — the factory/`Class.new` path is unaffected.) The no-`version` guard cannot live there — `version` is never called — so it lives in the option-B branch of `tool_name` derivation: when the final segment matches `/\Av\d+\z/i` but `_tool_version` is nil, raise instead of deriving. Both reuse the same segment regex.

### `tool_name(adapter = nil)` derivation

Between the explicit-override tiers and the existing prefix-strip/snake_case/sanitize derivation, insert the option-B step: when `_tool_version` is non-nil (version declared) and the class's final constant segment matches `/\Av\d+\z/i`, derive from the segments *excluding* that final segment (the enclosing namespace). Explicit `tool name:` and per-adapter bag names still short-circuit ahead of all derivation, unchanged. A class whose only segment is `::Vn` (no enclosing namespace) falls through to the existing never-blank fallback.

### Registry — identity `(tool_name, version)`

A new value object **`Axn::Tools::VersionGroup`** is the single place latest/default resolve. Built from the members of one `(adapter, tool_name)` group, on construction it validates the group and exposes:

- `.all` — members sorted ascending by `tool_version`.
- `.latest` — the `max(tool_version)` member.
- `.default` — the member flagged `_tool_version_default`, else the earliest (`min(tool_version)`) member.

Construction raises on a duplicate `tool_version` within the group (the relaxed `_assert_unique_tool_names!`, message now naming the version) and on two members flagged `default: true`.

- **`tools_for(adapter)`** groups all members by `tool_name(adapter)`, builds a `VersionGroup` per group, takes each group's `.latest`, and sorts by `tool_name`. Unversioned tools form groups of one ⇒ `.latest` is the tool itself ⇒ behavior is unchanged. The per-group construction still enforces uniqueness — two unrelated unversioned classes deriving the same name are both version 1 ⇒ duplicate-version collision ⇒ raise, exactly as today.
- **`tools_for(adapter, all_versions: true)`** returns every member, sorted by `(tool_name(adapter), tool_version)`. It builds the same `VersionGroup`s (so the same validation runs) and flattens `.all`.
- **`versions_for(adapter, tool_name)`** returns the `VersionGroup` for one logical tool (the entry point for a path-routing adapter and for testing the movable-default semantics without an adapter).

Grouping keys on `tool_name(adapter)` throughout, so per-adapter name overrides and per-adapter latest/default resolution compose without extra plumbing.

### Reflection

`tool_version` is surfaced alongside `tool_name`/`semantic_hints` wherever reflection describes a tool, so adapters can read the version off the reflected descriptor. Per-version input/output schemas need no special handling — each version is its own class with its own schema.

## Filesystem convention (docs only, no magic)

Documented as convention; `version N` is the sole source of truth and nothing derives version from the filesystem.

- **Single version: stay flat** — `agent_tools/approve_loan.rb`. No folder until a second version is needed.
- **Second version: promote to a folder** — rename to `agent_tools/approve_loan/v1.rb` (adding `version 1`) and add `v2.rb` (`version 2`). With no `approve_loan.rb`, Zeitwerk treats `approve_loan/` as an implicit namespace module (`AgentTools::ApproveLoan`) and nests `::V1`/`::V2`. The namespace module never registers as a tool (it does not `include Axn`).
- **The promotion moves the Ruby constant** (`AgentTools::ApproveLoan` → `::V1`) but **not** the wire contract: identity is `tool_name`, decoupled from constant/path, so `/approve_loan` still resolves and MCP still sees `approve_loan`. Update direct constant references like any rename.
- **Grouping is semantic, not structural** — the registry groups by declared `tool_name`, never by folder shape. `vN.rb` is a recommended convention with no magic; option-B derivation is what keeps the name stable across the promotion.

## Guards and edge cases

- **Repeat `version`.** Last-wins on a single class is acceptable (a scalar attribute, unlike the `tool` DSL's membership); no repeat guard is added.
- **`default: true` on an unversioned/only version.** No-op — it is already the earliest/default.
- **Gaps.** `v1` + `v3` (no `v2`) is legal; `.default` is `v1`, `.latest` is `v3`.
- **Two `default: true` in a group.** Raises at group resolution (cross-file).
- **Duplicate `(tool_name, version)`.** Raises at group resolution, message names the version.
- **`::Vn` without `version`.** Raises at enumeration (`tool_name` derivation).
- **`::V2` with `version 3`.** Raises at declaration (inside the `version` DSL).
- **`.version` owned by a base class.** Raises at definition time, naming the ancestor.

## Acceptance

- `version 2, default: true` sets `tool_version` to 2 and flags the default; a class with no `version` has `tool_version` 1 and is its group's default.
- `version 0`, `version -1`, `version "2"` raise at declaration.
- `AgentTools::ApproveLoan::V2` declaring `version 2` derives `tool_name` `"approve_loan"`; `::V2` without `version` raises; `::V2` with `version 3` raises.
- A base class defining `.version` makes `include Axn` (or the subclass hook) raise, naming the ancestor; `tool_version` still resolves for all other tools.
- Two versions sharing a `tool_name` coexist in the registry; `tools_for(adapter)` returns only the latest; `tools_for(adapter, all_versions: true)` returns both; `versions_for(adapter, "approve_loan").default` is the earliest unless `default: true` moves it.
- Two classes with the same `(tool_name, version)` raise; two `default: true` in one group raise.
- Every existing unversioned tool and every existing `tools_for` / `tool_name` call behaves identically.

## Out of scope

- Adapter projection: `axn-openapi` path-routing + bare-path-pinned-to-`default`, and `axn-mcp`/`axn-ruby_llm` latest-only, are downstream follow-ups. This PR ships no adapter behavior.
- Any filename→version derivation.
- A per-adapter `default` override (a clean later addition on top of the single core pin if ever motivated).
- Changing `description`'s debug-defer behavior (its defer is correct; a possible `debug`→`warn` nudge is a separate follow-up).
