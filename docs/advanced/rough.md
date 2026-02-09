# Internal Notes

This page contains internal implementation notes for contributors and advanced users.

## Context Sharing

The inbound/outbound contexts are views into an underlying shared object. Modifications to one affect the other:

- Preprocessing inbound args implicitly transforms them on the underlying context
- If you also expose a preprocessed field on outbound, it will reflect the transformed value

## Logging and Debugging

For information about logging configuration, see the [Configuration reference](/reference/configuration):

- **Logger configuration**: [logger](/reference/configuration#logger)
- **Log levels**: [log_level](/reference/configuration#log-level)
- **Automatic logging**: [Automatic Logging](/reference/configuration#automatic-logging)

### `execution_context`

The `execution_context` method returns a structured hash for exception reporting and handlers:

```ruby
{
  inputs: { ... },   # Filtered inbound fields (sensitive values removed)
  outputs: { ... },  # Filtered outbound fields (sensitive values removed)
  # ... any extra keys from set_execution_context or additional_execution_context hook
}
```

This is automatically passed to the `on_exception` hook. See [Adding Additional Context to Exception Logging](/reference/configuration#adding-additional-context-to-exception-logging) for customizing the context.

**Private methods for automatic logging:**
- `inputs_for_logging` - Returns only filtered inbound fields (used by pre-execution logs)
- `outputs_for_logging` - Returns only filtered outbound fields (used by post-execution logs)

These private methods do NOT include additional context from `set_execution_context` or the hook—they are specifically for automatic logging which only needs to show what the action was called with and what it produced.

### `#inspect` Support

Action instances provide a readable `#inspect` output that shows:
- The action class name
- Field values (with sensitive values filtered)
- Current execution state
