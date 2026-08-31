# PRO-2996 downstream cleanup — paste-ready prompts for axn-mcp / axn-ruby_llm / axn-openapi

Core's half of PRO-2996 shipped `Axn::Tools::AdapterSerialization` (a sibling mixin to
`Axn::Tools::AdapterRoots`) and `Axn::Tools::AdapterRoots#tool_roots_default`. See
`lib/axn/tools/adapter_serialization.rb`, `lib/axn/tools/adapter_roots.rb`, and
`docs/recipes/authoring-tool-adapters.md` (sections "Directory-based membership", "Value
serialization", "Per-adapter configuration" → `reject_opaque_exposed_values`, and "Never let the
mapping escape") for the shipped API this cleanup routes through.

**Gate: do not run any of the three prompts below until axn alpha.6 (or later) is released to
RubyGems and this ticket's core PR has merged.** All three gems pin `axn ">= 0.1.0-alpha.5", "<
0.2.0"` from RubyGems, not a git revision — `Axn::Tools::AdapterSerialization` does not exist on
that floor, so a session started early will fail at `require` and should stop rather than work
around it (e.g. by vendoring or git-pinning core — don't).

Each prompt below is self-contained: paste ONE of them as the first message into a **fresh** Claude
Code session opened in that gem's own checkout (not this one). Do not paste more than one prompt
into the same session — each targets a different repo. Run each in its own gem's working directory.

Shared acceptance bar for all three (from the PRO-2996 ticket, restated here so each session can
self-check without the ticket):
- No adapter repeats the `AdapterRoots.validate!` lambda.
- No adapter reads `config.reject_opaque_exposed_values` directly; it resolves per-tool through
  `serialize_exposed` (or `guard_tool_response`'s own resolution for the hint).
- Existing per-tool override specs still pass **unchanged in behavior** — they are the regression
  net for "no behavior change" on the config/render side. The guard's `on_exception`/`raises_in_dev?`
  behavior for axn-openapi is a deliberate ADDITION (it had none before), not a regression risk.
- `bundle exec rspec` and `bundle exec rubocop` green; gemspec floor bumped to the released version.

---

## Prompt 1 — axn-mcp

```
Cut over axn-mcp to axn's new Axn::Tools::AdapterSerialization mixin (core's PRO-2996 alpha.6
release). Read axn's docs/recipes/authoring-tool-adapters.md sections "Directory-based membership",
"Value serialization", "Per-adapter configuration" (`reject_opaque_exposed_values`), and "Never let
the mapping escape" first — that's the API you're routing through, with worked examples. Also read
AGENTS-tool-adapters.md in the axn gem for the dense-checklist version.

1. Bump the floor: axn-mcp.gemspec's `spec.add_dependency "axn", ">= 0.1.0-alpha.5", "< 0.2.0"` ->
   `">= 0.1.0-alpha.6"` (confirm the exact released version first: `gem list axn --remote --all` or
   check rubygems.org). Run `bundle update axn` and confirm `Gemfile.lock` picks it up.

2. lib/axn/mcp.rb: add `extend Axn::Tools::AdapterSerialization` alongside the existing
   `extend Axn::Tools::AdapterRoots` (both after `extend Axn::Configurable`, both before
   `config_namespace :mcp` per the existing order — AdapterSerialization's declare method must run
   AFTER config_namespace, same as any other overridable setting).
   - Replace `setting :tool_roots, default: %w[agent_tools], validate: ->(value) {
     Axn::Tools::AdapterRoots.validate!(value) }` with `tool_roots_default %w[agent_tools]`.
   - Replace `setting :reject_opaque_exposed_values, default: false, one_of: [true, false],
     overridable: true` with `declare_reject_opaque_exposed_values! default: false`. Keep the
     existing comment explaining WHY false (LLM output; ugly beats failed) — that reasoning is
     adapter-specific and doesn't move to core.

3. lib/axn/mcp/serializer.rb: `result_to_mcp_response` currently takes a pre-resolved
   `reject_opaque_exposed_values:` kwarg and calls
   `Axn::Extensions::Serialization.render(result, reject_opaque: reject_opaque_exposed_values)`.
   Replace that call with `Axn::MCP.serialize_exposed(result)` and DROP the
   `reject_opaque_exposed_values:` kwarg from `result_to_mcp_response`'s signature entirely — the
   resolution now happens inside `serialize_exposed`, keyed off `result.__action__.class`, so there
   is no longer anything for a caller to pass wrong.

4. lib/axn/mcp/wrap.rb: currently resolves
   `reject_opaque_exposed_values: Axn::MCP.resolve_override_for(axn_class, :reject_opaque_exposed_values)`
   and threads it into `Invocation.perform`. Delete that resolution and stop passing it through —
   `Invocation.perform` no longer needs the kwarg either (see next step). Leave `present_as`
   resolution exactly as it is; that setting stays adapter-owned, not part of this mixin.

5. lib/axn/mcp/invocation.rb: `perform` currently takes `reject_opaque_exposed_values:`, wraps
   `Serializer.result_to_mcp_response` in a hand-rolled `begin/rescue StandardError` that reports via
   `Axn::Extensions.best_effort` + `Axn.config.on_exception`, builds a `reject_opaque_exposed_values`
   hint inline, and re-raises via `raise if Axn::Extensions.raises_in_dev?`. Replace that whole
   `begin/rescue` with a call to `Axn::MCP.guard_tool_response(axn_class, on_error: ->(e) {
   ...your existing hint-building + Serializer.error_response(...) logic goes in this lambda... })
   { Serializer.result_to_mcp_response(result, text_content:) }`. Drop
   `reject_opaque_exposed_values:` from `perform`'s own signature — nothing upstream passes it in
   anymore.
   - IMPORTANT: the existing inline hint ("if this is an opaque-value rejection: ... resolved true
     for #{axn_class} ... unset it via configure(:mcp) ... or gem-wide via
     Axn::MCP.config.reject_opaque_exposed_values = false") reads
     `reject_opaque_exposed_values` — which is no longer passed into `perform`. Re-resolve it
     independently inside the `on_error` lambda: `Axn::MCP.resolve_override_for(axn_class,
     :reject_opaque_exposed_values)`. This is a second read of the same override, which is fine —
     it's only used to build a diagnostic string, not to gate behavior.
   - `guard_tool_response` already does the `best_effort`-wrapped `on_exception` report and the
     `raises_in_dev?` re-raise for you — don't keep your own copies of either.

6. Run `bundle exec rspec`. The regression net is spec/axn/mcp/wrap_spec.rb's "reject_opaque_exposed_values
   resolution" block, spec/axn/mcp/serializer_spec.rb's opaque-value examples, and
   spec/axn/mcp/invocation_spec.rb's "transport-failure guard" block — all four per-tool-override
   directions (gem-wide false, gem-wide true, per-class true, per-class false beats gem-wide true)
   and all five guard behaviors (error response, on_exception report, dev re-raise, broken-reporter
   resilience, "any StandardError not just serialization") must still pass with IDENTICAL observable
   behavior. If any fails, that's a real regression to fix, not a spec to update — the acceptance bar
   is "no behavior change" on this half.

7. Run `bundle exec rubocop`. Update CHANGELOG.md under `## Unreleased` (or the current unreleased
   heading — check `git tag`/rubygems the same way axn-core's AGENTS.md prescribes) with an
   `[INTERNAL]` entry: routed through axn core's shared `Axn::Tools::AdapterSerialization` (PRO-2996);
   no behavior change on the config/render side.
```

---

## Prompt 2 — axn-ruby_llm

```
Cut over axn-ruby_llm to axn's new Axn::Tools::AdapterSerialization mixin (core's PRO-2996 alpha.6
release). Read axn's docs/recipes/authoring-tool-adapters.md sections "Directory-based membership",
"Value serialization", "Per-adapter configuration" (`reject_opaque_exposed_values`), and "Never let
the mapping escape" first. Also read AGENTS-tool-adapters.md in the axn gem for the dense-checklist
version.

1. Bump the floor: axn-ruby_llm.gemspec's `spec.add_dependency "axn", ">= 0.1.0-alpha.5", "< 0.2.0"`
   -> `">= 0.1.0-alpha.6"` (confirm the exact released version first). Run `bundle update axn`.

2. lib/axn/ruby_llm.rb: add `extend Axn::Tools::AdapterSerialization` alongside the existing
   `extend Axn::Tools::AdapterRoots` (this gem's `config_namespace :ruby_llm` is declared in
   tool_adapter.rb, not here — see step 3; that's fine, `tool_roots_default` doesn't need
   config_namespace at all, only `declare_reject_opaque_exposed_values!` does, and that call moves
   with the rest of the settings in tool_adapter.rb).
   - Replace `setting :tool_roots, default: ["agent_tools"], validate: ->(value) {
     Axn::Tools::AdapterRoots.validate!(value) }` with `tool_roots_default %w[agent_tools]`.

3. lib/axn/ruby_llm/tool_adapter.rb (top of file, alongside `config_namespace :ruby_llm` and the
   other `setting` calls): replace `setting :reject_opaque_exposed_values, default: false, one_of:
   [true, false], overridable: true` with `declare_reject_opaque_exposed_values! default: false`.
   `Axn::Tools::AdapterSerialization` must already be extended onto `Axn::RubyLLM` by this point
   (it is, from step 2, since `ruby_llm.rb` is required before `tool_adapter.rb` reopens the
   module — confirm the require order still holds).

4. `ToolAdapter.wrap` currently resolves `reject_opaque: Axn::RubyLLM.resolve_override_for(axn_class,
   :reject_opaque_exposed_values)` and passes it into `build_tool_class`, which closes over it at
   WRAP time (not per-call, unlike axn-mcp). Routing through `serialize_exposed` moves this
   resolution to PER-CALL instead (inside `#execute`, at the point `serialize_exposed(result)` is
   called) — this is a deliberate, correct behavior change (a gem-wide/per-tool config change now
   takes effect for already-wrapped tools, matching axn-mcp's existing per-call semantics), NOT a
   bug. Call it out explicitly in this gem's CHANGELOG as `[BUGFIX]` or `[BREAKING]` per your judgment
   of how visible the old wrap-time-only resolution was to consumers — read AGENTS.md's `[BREAKING]`
   convention in axn-core if unsure which tag fits. Delete the `reject_opaque:` resolution from
   `wrap`/`build_tool_class` entirely; it's no longer threaded through as a kwarg.

5. Inside `#execute` (the block currently doing
   `payload = if present_as == :message then result.message else
   Axn::Extensions::Serialization.render(result, reject_opaque:).to_json end`): replace the
   `Axn::Extensions::Serialization.render(result, reject_opaque:)` call with
   `Axn::RubyLLM.serialize_exposed(result)`. `present_as` resolution is untouched (adapter-owned,
   not part of this mixin).

6. The `begin/rescue StandardError => e` guard around that same mapping step (report via
   `Axn::Extensions.best_effort` + `Axn.config.on_exception`, `raise if
   Axn::Extensions.raises_in_dev?`, else `{ error: ADAPTER_FAILURE_MESSAGE }`) — replace the whole
   `begin/rescue` with `Axn::RubyLLM.guard_tool_response(axn_class, on_error: ->(_e) { { error:
   ADAPTER_FAILURE_MESSAGE } }) do ... end`, with `halt_after ? halt(payload) : payload` INSIDE the
   guarded block (the block's return value becomes `#execute`'s return value either way). There is a
   comment at this exact site (search for "PRO-2996 §2b") saying "Shaped to drop into the planned
   shared Axn::Tools::Serialization.guard ... with no behavior change" — update/delete that comment
   now that it's landed, and note the ACTUAL name is `Axn::Tools::AdapterSerialization#guard_tool_response`,
   not `Axn::Tools::Serialization.guard` (the ticket's working name changed during implementation).

7. Run `bundle exec rspec`. The regression net is spec/axn/ruby_llm/tool_adapter_spec.rb's
   "serialization failures surface as a tool error" block, its "transport-failure guard" block
   (explicitly commented "axn-mcp parity" — same five behaviors: reports via on_exception, dev
   re-raise, guards any StandardError not just serialization, broken-reporter resilience, and the
   plain success/error mapping), and its per-tool override block (all four directions). All must
   still pass — except the wrap-time-vs-per-call resolution timing change from step 4, which is an
   INTENDED behavior change; if an existing spec asserts wrap-time-only resolution, update that one
   spec (not the others) to assert per-call resolution instead, and say so in the commit.

8. Run `bundle exec rubocop`. Update CHANGELOG.md with the `[BUGFIX]`/`[BREAKING]` entry from step 4
   plus an `[INTERNAL]` entry for the AdapterSerialization cutover generally.
```

---

## Prompt 3 — axn-openapi

```
Cut over axn-openapi to axn's new Axn::Tools::AdapterSerialization mixin (core's PRO-2996 alpha.6
release). Read axn's docs/recipes/authoring-tool-adapters.md sections "Directory-based membership",
"Value serialization", "Per-adapter configuration" (`reject_opaque_exposed_values`), and "Never let
the mapping escape" first. Also read AGENTS-tool-adapters.md in the axn gem for the dense-checklist
version.

1. Bump the floor: axn-openapi.gemspec's `spec.add_dependency "axn", ">= 0.1.0-alpha.5", "< 0.2.0"`
   -> `">= 0.1.0-alpha.6"` (confirm the exact released version first). Run `bundle update axn`.

2. lib/axn/openapi.rb: add `extend Axn::Tools::AdapterSerialization` alongside the existing
   `extend Axn::Tools::AdapterRoots` (both before `config_namespace :openapi`, or after it but
   before `declare_reject_opaque_exposed_values!` — same ordering rule as the other two gems).
   - Replace `setting :tool_roots, default: %w[agent_tools], validate: ->(v) {
     Axn::Tools::AdapterRoots.validate!(v) }` with `tool_roots_default %w[agent_tools]`.
   - Replace `setting :reject_opaque_exposed_values, default: true, one_of: [true, false],
     overridable: true` with `declare_reject_opaque_exposed_values! default: true`. THIS GEM'S
     DEFAULT IS true, unlike the other two — keep it that way; don't copy axn-mcp/axn-ruby_llm's
     `false`. Keep the existing comment explaining why (published HTTP contract; opaque output is a
     bug here, unlike an LLM-facing adapter).

3. lib/axn/openapi/dispatcher.rb's `#success` method currently does:
     reject_opaque = Axn::OpenAPI.resolve_override_for(axn_class, :reject_opaque_exposed_values)
     Dispatch.new(200, Axn::Extensions::Serialization.render(result, reject_opaque:))
   Replace the two lines with `Dispatch.new(200, Axn::OpenAPI.serialize_exposed(result))`.

4. `#success`'s `rescue StandardError, SystemStackError => e` block is THIS GEM'S DIFFERENCE from the
   other two: today it only logs (`Axn.config.logger.error { ... }` with the two-level
   `reject_opaque_exposed_values` hint, naming the tool and both config levels) and NEVER calls
   `Axn.config.on_exception` or re-raises in dev. Routing through `guard_tool_response` is a
   DELIBERATE behavior addition (this gem gains on_exception reporting and raises_in_dev? — the
   PRO-2996 ticket's acceptance criteria explicitly asks for every adapter's wrapper to report via
   on_exception and honor raises_in_dev?, which this gem currently does not). This is NOT covered by
   "no behavior change" — it's a real, intended addition; call it out in this gem's CHANGELOG as
   `[FEAT]` or `[BUGFIX]` (your call — arguably a bugfix, since a swallowed unreported exception in
   a tool adapter is the exact defect class PRO-2996 exists to close).
   - Wrap only the render+Dispatch.new line in `Axn::OpenAPI.guard_tool_response(axn_class, on_error:
     ->(e) { ...your existing hint-logging + Dispatch.new(500, GENERIC_500)... }) { ... }`.
   - PRESERVE the existing hint text and its structure exactly (naming the tool AND both config
     levels — this is regression-pinned, see step 6) inside the `on_error` lambda; it needs to
     independently resolve `reject_opaque = Axn::OpenAPI.resolve_override_for(axn_class,
     :reject_opaque_exposed_values)` again there (the guard doesn't hand you the resolved value,
     only the exception), same as axn-mcp's cleanup.
   - `#ensure_encodable` (the `JSON.generate(dispatch.body)` re-encode check right after dispatch,
     rescuing `StandardError, SystemStackError` and logging only) is a SEPARATE guard over the
     ENCODE step, not the render step `guard_tool_response` covers — leave it as-is; don't fold it
     into the same guard call. Confirm with the ticket/docs that these are meant to stay two guards,
     not one, before merging them "for consistency" — they cover genuinely different failure points
     (render vs. final JSON.generate) and axn-mcp/axn-ruby_llm don't have an equivalent second guard
     because they don't re-encode separately.

5. Run `bundle exec rspec`. The regression net is spec/axn/openapi/dispatcher_spec.rb's "the
   opaque-rejection log hint" describe block (asserts the hint names the tool, `configure(:openapi)`,
   AND `Axn::OpenAPI.config.reject_opaque_exposed_values` — all three strings must still appear) and
   its "per-tool override via configure(:openapi)" block (both directions: opt-out under a strict
   gem-wide default, opt-in under a lenient one). spec/axn/openapi/spec_generator_spec.rb's
   `reject_undeclared_inputs` tests are UNRELATED to this mixin (that setting stays a hand-rolled
   `overridable:` setting, not part of `AdapterSerialization` — don't touch it) and must be
   unaffected. NEW behavior to add tests for: `Axn.config.on_exception` now gets called on a
   serialization failure (it didn't before) — assert it, and assert `raises_in_dev?` now re-raises
   in dev instead of always returning a 500.

6. Run `bundle exec rubocop`. Update CHANGELOG.md with both the AdapterSerialization cutover
   ([INTERNAL]) and the on_exception/raises_in_dev? addition from step 4 ([FEAT]/[BUGFIX], your call).
```
