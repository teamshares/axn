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

### `context_for_logging`

The `context_for_logging` method returns a hash of the action's context, with:
- Filtering to accessible attributes
- Sensitive values removed (fields marked with `sensitive: true`)

This is automatically passed to the `on_exception` hook. See [Adding Additional Context to Exception Logging](/reference/configuration#adding-additional-context-to-exception-logging) for customizing the context.

### `#inspect` Support

Action instances provide a readable `#inspect` output that shows:
- The action class name
- Field values (with sensitive values filtered)
- Current execution state
