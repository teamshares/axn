# Authenticating Inbound Requests

This recipe is for **gem authors** whose gem accepts requests from outside the process on axn's behalf — an HTTP tool endpoint ([axn-openapi](https://github.com/teamshares/axn-openapi)), an inbound webhook ([axn-webhooks](https://github.com/teamshares/axn-webhooks)). `Axn::Extensions::Auth` holds the pieces every such gem otherwise re-implements, each with the same security bugs to rediscover.

It is transport-free: axn has no Rack dependency, so a **request** is any object answering `#header(name)`. Adapt your gem's own request object to that one method.

## Strategies and verdicts

A **strategy** is any object answering `#call(request)` with a **verdict**:

- an `Axn::Extensions::Auth::Verdict` (`ok`, `reason`, `principal`),
- anything else answering `ok?` (optionally `reason` and `principal`), or
- a bare boolean.

Read a strategy's answer with `Auth.normalize(verdict)`, which always returns a `Verdict`, and never carries a principal on a rejection. If you need only yes/no, use `Auth.verified?(verdict)`. It asks `ok?` **before** truthiness, because a rejecting verdict object (an `Axn::Result`, say) is still truthy.

```ruby
verdict = Axn::Extensions::Auth.normalize(strategy.call(request))
verdict.ok?        # => false
verdict.reason     # => :credentials_mismatch
verdict.principal  # => nil
```

A strategy may also publish metadata for the gem serving it. All of it is optional:

| Method | Meaning |
|---|---|
| `#principals` | The ids it can authenticate, so you can check an allowlist against them at boot. |
| `#unauthorized_headers` | A challenge to attach to a 401 (`{ "www-authenticate" => "Bearer" }`). |
| `#scheme` / `#header` | A neutral description you map onto your own vocabulary, such as an OpenAPI security scheme. |

## The built-in `Bearer` strategy

```ruby
Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => -> { ENV.fetch("PIPELINE_API_KEY") } })
Axn::Extensions::Auth::Bearer.new(keys: { "svc" => %w[old-key new-key] }, header: "X-API-Key")
```

- **Where it reads the key.** Each principal id names one or more keys. By default the key comes from `Authorization: Bearer <key>`. With `header:`, it's the raw value of that header instead.
- **What a key can be.** A String, a Proc, or an Array of those. A Proc is resolved **on every request**: a zero-arity Proc is simply called, and a one-arity Proc receives the request. A Proc may return an Array. Listing the old and new key together is how a rotation overlaps.
- **Timing.** Every candidate key of every principal is compared, with no early exit. The comparison is constant-time and length-independent.
- **Misconfiguration raises instead of rejecting.** A blank or non-String key, or one with leading or trailing whitespace (which a stripped token could never match), raises `Auth::ConfigurationError`: a literal one at construction, a deferred one on the request. So does one token authenticating as two principals, and (at construction) two principal ids that stringify alike, such as `:svc` and `"svc"`. A 401 that really means "we are misconfigured" would otherwise look like an unexplained outage.
- **Redaction.** `inspect` and `pp` never render a key.

## The primitives

For gems writing their own strategies:

- **`Auth.secure_compare(a, b)`**: constant-time and length-independent (it hashes both sides first). Returns false on nil and never raises. For a fixed-width value such as an HMAC signature, a plain `OpenSSL.fixed_length_secure_compare` after a length check is equally safe.
- **`Auth.require_secret!(declaration, value, label:, error:)`**: the secret guard. A blank secret is a **weak key**, not a failure: `""` compares equal to an empty credential and is a legal HMAC key. Route every secret through this, in both directions. Use its **return value**: a frozen plain-String copy, so a String subclass's overrides never run downstream and later mutation of the caller's object cannot change it. Its message names the value's type or emptiness, never its bytes.
- **`Auth.deferred?(value)` / `Auth.resolve(value, request)`**: per-request resolution of a Proc. Everything else, including a Symbol, is a literal. Resolving a Symbol against the request is a DSL convention your gem can layer on top (axn-webhooks does), not something core guesses at.

## Observability

Run the authentication step **as an Axn** (`fail!` on rejection). Every request then gets axn's `axn.call` event, span and log line, including rejected ones that never reach a handler. Pair it with a `reason` dimension and your gem's [entry-point stamp](/recipes/declaring-entry-points). axn-webhooks' `Verify` stage and axn-openapi's gate both follow this pattern. `Axn::Extensions::Tracing.annotate_span` can't do this job, because it writes only to a running Axn's span.
