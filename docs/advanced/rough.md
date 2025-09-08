::: danger ALPHA
* TODO: convert rough notes into actual documentation
:::

## Rough Notes

* General note: the inbound/outbound contexts are views into an underlying shared object (passed down through organize calls) -- modifications of one will affect the other (e.g. preprocessing inbound args implicitly transforms them on the underlying context, which is echoed if you also expose it on outbound).

* `context_for_logging` (and decent #inspect support)

* Configuring logging (will default to Rails.logger if available, else fall back to basic Logger (but can explicitly set via e.g. `Axn.config.logger = Logger.new($stdout`))

    * Note `context_for_logging` is available (filtered to accessible attrs, filtering out sensitive values). Automatically passed into `on_exception` hook.

