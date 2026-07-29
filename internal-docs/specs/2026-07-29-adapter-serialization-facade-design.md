# Narrow the adapter-facing serialization surface behind Axn::Extensions (PRO-2992)

/ Linear: https://linear.app/teamshares/issue/PRO-2992

## Problem

Adapter gems render a successful result's exposures by calling `Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)` — reaching into a namespace that sits beside `Reflection::Schema` and `Reflection::Coercion` and looks internal because it is. Every public method in that module is therefore load-bearing by accident, and the cost has already been paid rather than predicted: PRO-2988 (PR #206) had to carry the constraint "`follow_as_json?` must remain a working public method with unchanged semantics — `axn-openapi` calls it at `lib/axn/openapi/serializer.rb:47`" through a refactor of core's own `as_json`/`to_h` routing. A downstream gem's reach into an internal predicate constrained core.

Schema reflection has no equivalent problem, and the contrast is the point: adapters read schemas through `axn_class.input_schema`/`output_schema`, first-class accessors on the action class, and the docs can flatly say "don't reach into `Axn::Reflection::Schema` internals." Value serialization never got that accessor, so the internals *are* the interface.

## What the audit found

The `axn-openapi` cleanup that this ticket was sequenced behind is done in that gem's working tree: `assert_serializable!` is gone from `lib/`, and `follow_as_json?` now has **zero callers anywhere** — core, specs, or gems.

All three adapters call exactly one method, and all three pass `axn_class.external_field_configs` verbatim:

- `axn-mcp/lib/axn/mcp/serializer.rb:13`, fed from `invocation.rb:41`
- `axn-openapi/lib/axn/openapi/serializer.rb:30`, fed from `dispatcher.rb:88`
- `axn-ruby_llm/lib/axn/ruby_llm/tool_adapter.rb:100`, inline

`axn-ruby_llm:103` also rescues `Axn::Reflection::UnserializableValue` by name. `axn-webhooks` has no serialization call sites at all.

Core itself needs exactly one method from the module: `Reflection::Schema.normalize_scalar_literal` calls `Values.serialize_value` (`schema.rb:891`). The other eighteen public methods — `encodable_string!`, `utf8_rendering`, `transcode_to_utf8`, `finite_number!`, `coerce_to_float`, `within_container`, `capture_hash_entries`, `own_wire_key`, `no_entries_lost!`, `raise_colliding_fields!`, `owner_of`, `canonical_wire_key`, `capture_elements`, `raise_colliding_keys!`, `describe_key_classes`, `check_opaque_key!`, `projection_for`, `default_to_s?` — have no caller outside the module, not even in specs.

## Decisions

### 1. One entry point, and it derives the field configs

New file `lib/axn/extensions/serialization.rb`:

```ruby
Axn::Extensions::Serialization.render(result, reject_opaque: false)
```

The `field_configs` argument the ticket sketched is **dropped**: core derives them from `result.__action__.class.external_field_configs` (`__action__` is a reserved public accessor on `Result`). Every call site passed `external_field_configs` verbatim anyway, so the argument was plumbing; and passing a *filtered* list — the only thing the argument made possible — silently produces a body that no longer matches the reflected `output_schema`, which is the promise this serializer exists to keep. Removing the argument closes that footgun rather than documenting it.

`external_field_configs` stays part of the adapter surface regardless: `axn-mcp/lib/axn/mcp/wrap.rb:70` reads `.empty?` on it to decide whether to declare an output schema at all.

Rendering semantics are unchanged — same output, same `Axn::Reflection::UnserializableValue`, same split between the unconditional guarantees and what `reject_opaque:` buys.

`Serialization` is a nested module rather than a method on `Axn::Extensions` itself: that module holds process-level helpers (`best_effort`, `swallowable?`, `config`), and serialization is a distinct concern with room to grow.

### 2. The narrowing has teeth in the code, not only in the docs

- **`follow_as_json?` is deleted.** Zero callers; `projection_for` was already the single source of truth for the same question. Nothing is released, so per the tombstone convention a dead method is removed outright rather than tombstoned.
- **`serialize_exposed` becomes `private_class_method`.** Its only caller is the facade, which reaches it with `send` — the idiom `executor.rb:529` already uses for `external_field_configs`. This is what makes `render` the *only* supported rendering path instead of a second one beside the old one.
- **All eighteen helpers become `private_class_method`.** They have no external caller, so this costs nothing and closes the whole namespace rather than the one predicate that happened to bite. `module_function` plus `private_class_method` composes correctly: the module's own calls use an implicit receiver, which private methods allow.
- **`serialize_value` stays public**, and this is the one place the boundary is documentary rather than enforced. `Reflection::Schema` calls it cross-module and 134 spec call sites exercise it directly (124 in `values_spec.rb`, 10 in the Rails dummy app's); privatizing it would buy one `send` in `Schema` and 134 in specs. It gets a comment marking it core-internal and stops being named in any adapter-facing doc.
- **`Axn::Reflection::UnserializableValue` keeps its name and home.** Adapters rescue it by name, renaming is pure churn, and the fix is to present it as the facade's declared failure mode rather than as a coordinate inside `Reflection`.

### 3. Docs stop pointing adapter authors at `Reflection::Values`

- `AGENTS-tool-adapters.md` — the Value serialization section and its `Source:` line.
- `docs/recipes/authoring-tool-adapters.md` — both code samples, the "pass `axn_class.external_field_configs` as the second argument" instruction (now gone), and the result-handling sketch around L220.
- `docs/reference/class.md:811` — the sentence pairing `input_schema`/`output_schema` with `serialize_exposed`.
- `AGENTS.md:83` keeps its reference: that one is guidance about core's own no-dispatch discipline in error paths, not an adapter pointer.

### 4. Tests

New `spec/axn/extensions/serialization_spec.rb` takes the six examples from `values_spec.rb`'s `describe ".serialize_exposed"` block, which already build a real action class and pass `klass.external_field_configs` — so they migrate by dropping the argument. Two examples are added: that only declared `exposes` fields render (the derivation is correct, not merely present), and that `reject_opaque:` threads through to values. The block leaves `values_spec.rb`; its `serialize_value` coverage stays as-is, as does `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb`, which only touches `serialize_value`.

## Scope boundary

Core only. The three adapter gems pin axn by git *revision* in their lockfiles, so nothing breaks until each bumps deliberately; each then migrates in its own repo, and `axn-openapi` folds the switch into the PR already rewriting `serializer.rb`. `axn-webhooks` has nothing to migrate and gets the facade by default when it grows a serialization path.

## Non-goals

- No rename or relocation of `Axn::Reflection::Values` to `Axn::Internal::*`. It would break symmetry with `Reflection::Schema`, which is equally internal and staying put, and would drag the public `UnserializableValue` into a namespace question that has no upside.
- No change to what gets rendered, to `reject_opaque:` semantics, or to any error message.
- No deprecation cycle. Nothing is released.
