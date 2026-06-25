# Wrapping External Service Clients

A convention several Axn-based apps have converged on: wrap each external service (a third-party API, a vendor SDK, an internal service) in a single class that `include`s `Axn`, memoizes the underlying connection, and mounts one action per operation via [`mount_axn_method`](/advanced/mountable#mount_axn_method-strategy).

This is a **convention, not a framework requirement** — nothing in Axn enforces it. It's written up here because it has been consistently useful, and because the choice of `mount_axn_method` (rather than `mount_axn`) is deliberate in a way that's worth understanding before you copy the pattern.

## The shape

One class per service. Memoize the client/connection privately, then mount one operation per `mount_axn_method`:

```ruby
class Clients::Payments
  include Axn

  mount_axn_method :create_charge,
    expects: { card_token: { sensitive: true } },
    error: ->(exception:) { PaymentErrorMessage.user_message(exception, fallback: CHARGE_ERROR_FALLBACK) } do |amount_cents:, card_token:|
    payment_client.charge(amount_cents:, source: card_token)
  end

  mount_axn_method :refund, expects: { charge_id: { type: String } } do |charge_id:|
    payment_client.refund(charge_id)
  end

  private

  memo def payment_client # [!code focus]
    PaymentProvider::Client.new(api_key: ENV["PAYMENT_PROVIDER_API_KEY"])
  end
end
```

Each block returns a single value (the API response), so `mount_axn_method` auto-exposes it as `value`. Shared concerns — credentials, the memoized client, error-message constants — live on the wrapper, out of the individual operations.

## Why `mount_axn_method`, not `mount_axn`

This is the load-bearing decision. `mount_axn_method` gives you a single bang method that **raises on failure and returns the exposed value directly**:

```ruby
# Returns the charge object directly; raises if the call fails.
charge = Clients::Payments.create_charge!(amount_cents:, card_token:)
```

That's the ergonomic common case. But the full [`Result` interface](/reference/axn-result) is *also* available — mounting always generates an `Axns` namespace alongside the convenience method:

```ruby
# Returns a Result; branch on ok? instead of rescuing.
result = Clients::Payments::Axns.refund(charge_id:)
if result.ok?
  redirect_to receipt_path, success: "Refund issued."
else
  flash[:error] = result.error
end
```

So one `mount_axn_method` gives you **both** interfaces, and the *caller* picks per call site:

- `Service.op!(...)` — when you want the value and a failure should raise.
- `Service::Axns.op(...)` — when you want to handle failure gracefully (e.g. a controller rendering an error).

Switching the mount to `mount_axn` would put the non-bang `Result` method directly on the wrapper (`Service.op(...)`), saving the `::Axns` segment — but at the cost of the auto-value-return: `op!` would then hand back a `Result` instead of the value, so every `Service.op!(...)` site would need a trailing `.value`. Since the value-return case is overwhelmingly the common one, that's a net loss. Reach into `::Axns` for the occasional `Result`; keep the convenience method for everything else.

## Map vendor errors at the boundary

The wrapper is the right place to translate vendor-specific exceptions into user-facing `result.error` strings, so callers never have to know the shape of the underlying API's errors. Use a per-operation `error:` handler, or — when a whole service shares error semantics — declare them once on a base class keyed by exception class:

```ruby
error "Payment failed. Please try again.", if: PaymentProvider::Error
error "That charge wasn't found.", if: PaymentProvider::NotFoundError
error "Please sign in again.", if: PaymentProvider::AuthenticationError
```

Order matters: the **last** matching `error` wins. When the vendor's exceptions form a hierarchy (e.g. `AuthenticationError < PaymentProvider::Error`), declare the broad catch-all first and the more-specific classes last, so a specific match isn't shadowed by the catch-all.

These resolve only for the non-bang (`Result`) path — the bang method still raises the original exception — which pairs naturally with the two-interface split above.

## Services with many endpoints: share a base

When a service has several resources, give it a `Base` that holds the connection (often via the [`:client` strategy](/strategies/client)) and shared helpers, then keep each resource thin:

```ruby
class Clients::Crm::Base
  include Axn

  use :client, name: :crm, url: "https://api.example.com/v2", headers: { ... }
end

class Clients::Crm::Contact < Clients::Crm::Base
  mount_axn_method :get do |id:|
    crm.get("contacts/#{id}").body["contact"]
  end
end
```

Subclasses inherit the connection and any shared private helpers; they only declare their own operations.

## When the pattern doesn't fit

`mount_axn_method` requires each operation to expose **exactly one** value (it auto-unwraps that single field). If an operation genuinely needs to expose multiple named fields, it can't use `mount_axn_method` — switch that operation to [`mount_axn`](/advanced/mountable#axn-strategy) (which returns the full `Result` from `op`/`op!` and exposes all fields), or have it return a single composite object. In practice external-service operations almost always map to one return value, so this is rare.

## See also

- [Mountable Actions](/advanced/mountable) — the `mount_axn_method` and `mount_axn` primitives this pattern builds on.
- [Client Strategy](/strategies/client) — the `use :client` HTTP connection helper used by the base-class flavor above.
- [Result Interface](/reference/axn-result) — what `Service::Axns.op(...)` hands back.
