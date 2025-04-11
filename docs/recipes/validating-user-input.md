# Validating _user_ input

::: danger ALPHA
This has not yet been fully fleshed out.  For now, the general idea is that user-facing validation is a _separate layer_ from the declarative expectations about what inputs your Action takes (e.g. `expects :params` and pass to a form object, rather than accepting field-level params directly).
:::


The `expects`/`exposes` validations are for confirming that you're fulfilling your contract with yourself to call your service correctly.  Any failures are _not_ user facing (and in fact, at some point may optionally raise in development)

If you want to run validations on user-provided data (i.e. individual form elements), there's a Form Object pattern for that.

