# Downstream Interface Contract Specs

These specs document and test the axn interfaces used by downstream gems. Failures here indicate that a change to axn's public (or relied-upon internal) API will require corresponding updates to the downstream gems.

## Purpose

- **Catch breaking changes** to interfaces used by `slack_sender`, `data_shifter`, and `axn-mcp`
- **Document contracts** for each downstream gem's usage of axn
- **Signal coordination needed** when changes affect downstream dependencies

## Covered Gems

| Spec File | Downstream Gem | Key Interface Usage |
|-----------|----------------|---------------------|
| `slack_sender_interface_spec.rb` | slack_sender | Strategy registration, `use :name`, expects/exposes, error(if:), call_async/call!, async adapter, ContractViolation::PreprocessingError |
| `data_shifter_interface_spec.rb` | data_shifter | include Axn, expects with type/default, hooks (around/before/on_success/on_error), Result.ok/error, result.ok?/exception |
| `axn_mcp_interface_spec.rb` | axn-mcp | Full expects/exposes DSL, call/call!, Result/Failure, field config access (internal_field_configs, external_field_configs, subfield_configs), Axn::Internal::FieldConfig.optional?, Testing::SpecHelpers |

## Notes

- These specs may duplicate coverage from other spec files. That's intentional.
- The `axn-mcp` spec covers some internal APIs (`internal_field_configs`, etc.) that axn-mcp relies on for schema generation. Changes to these internals should prompt either an axn-mcp update or a decision to expose a stable public API.
- When a spec fails here, check the corresponding downstream gem to understand the impact.
