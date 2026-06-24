# Forwarding helpers for facade actions: `expose(result)` + `inputs`

**Linear:** [PRO-2781](https://linear.app/teamshares/issue/PRO-2781/axn-sugar-for-a-cleaner-expose-result-when-dealing-with-nesting)
**Date:** 2026-06-23
**Status:** Design approved, ready for implementation plan

## Problem

A common Axn shape is a **thin facade**: an action whose job is to add a guard and/or a
domain-specific message, then delegate to a generic core action — forwarding most of its inputs
through and re-exposing the core's outputs. The motivating case is the os-app MFP/secondment
stack (os-app#4945):

```ruby
class Actions::Mfp::Assignment::Create
  include Axn

  expects :user, :company, :role, :started_at, optional: true
  exposes :user, optional: true
  exposes :employment, optional: true

  error "Unable to create assignment"
  before { fail! "…not an MFP user." unless user&.mfp? }

  def call
    result = Actions::Employment::AddEmployeeToCompany.call(user:, company:, role:, started_at:)
    expose user: result.user, employment: result.employment
    fail! result.error unless result.ok?
  end

  success { "#{user.full_name} has been assigned to #{company.display_name}." }
end
```

The `def call` body is three manual chores, none of which Axn helps with today:

1. **Input forwarding** — `call(user:, company:, role:, started_at:)` is just the action's own
   `expects` list retyped into the child call.
2. **Output re-exposing** — `expose user: result.user, employment: result.employment` re-lists
   every field by hand. This must run **before** `fail!`: on a failed child, `result.user` is the
   invalid record carrying `.errors`, which the form UI reads off the exposed `user`. Forwarding
   the child's outputs *regardless of outcome* is the whole point, so the ordering is load-bearing.
3. **Failure propagation** — `fail! result.error unless result.ok?`.

Chore #3 is resolved by the base-`error` prefixing landed in PRO-2746 (#109): a declared
`error "Unable to create assignment"` automatically contextualizes the child's propagated failure,
so the post-#109 form is non-bang `.call` + forward + a bare `fail! unless result.ok?` (a lingering
`fail! result.error` in a parent that declares a base error would now **double-prefix** — exactly
the hand-rolled-prefix trap #109's migration notes warn about). This spec addresses **chores #1 and
#2**, which #109 does not touch.

`steps` is explicitly **not** the answer here: it fails the parent the instant a step fails and
never copies that step's exposures back, so it would swallow the `user.errors` the form depends on.
Steps model sequential **pipelines**; these are 1:1 **facades** with a guard, a custom message, and
argument injection (`Secondment::Create` injects a constant `role: ROLE` the parent doesn't expect).

## Solution overview

Two small, independently useful primitives, composed inside an explicit `def call` (no declarative
`delegates_to` DSL — it would fight the guard, the custom `success`, and the load-bearing
expose-then-fail ordering these facades depend on; sugar like that is better layered on top of these
primitives later, once the pattern is proven):

```ruby
def call
  result = Actions::Employment::AddEmployeeToCompany.call(**inputs)   # #1: forward inbound
  expose(result)                                                      # #2: re-expose, failure-tolerant
  fail! unless result.ok?                                             # #3: handled by #109 base prefix
end
```

- **`expose(result)`** — overloads the existing `expose` to accept an `Axn::Result` and forward the
  intersection of the result's declared fields and this action's `exposes` into `exposed_data`.
- **`inputs`** — a reader returning this action's resolved inbound fields as a `Hash`, splattable
  straight into a child call, with plain `Hash` methods (`except`/`slice`) covering subsetting.

The MFP facade collapses to:

```ruby
def call
  result = Actions::Employment::AddEmployeeToCompany.call(**inputs)
  expose(result)
  fail! unless result.ok?
end
```

and the secondment facade, which injects the role constant and forwards the rest:

```ruby
def call
  result = Actions::Employment::AddEmployeeToCompany.call(**inputs.except(:role), role: ROLE)
  expose(result)
  fail! unless result.ok?
end
```

## `expose(result)` — re-expose a nested result

`expose` currently accepts either two positional args (`expose(:key, value)`) or a hash of
key/value pairs (`expose(key: value)`); a single positional arg raises `ArgumentError`. We
repurpose the **single-positional-`Axn::Result`** form (currently a guaranteed error, so this is
purely additive):

```ruby
def expose(*args, **kwargs)
  if args.size == 1 && args.first.is_a?(Axn::Result)
    return _expose_from_result(args.first)
  end
  # …existing two-positional / kwargs behavior unchanged…
end
```

`_expose_from_result(result)` forwards, for each field in
`result.declared_fields & self.class._declared_fields(:outbound)`:

```ruby
@__context.exposed_data[field] = result.public_send(field)
```

### Semantics

- **Field selection = intersection of declared contracts.** The fields forwarded are the
  *statically declared* exposures of the child (`result.declared_fields`) intersected with this
  action's own declared exposures. Your `exposes` stays the filter: a child that declares **more**
  than you never trips `UnknownExposure`; a field you declare but the child does not is simply not
  forwarded (your own outbound contract validation still catches it on success if it is required).
- **Failure-tolerant, by construction.** `declared_fields` is the static declared contract (set at
  facade construction from `self.class._declared_fields(direction)`), *not* a runtime record of
  what was actually exposed. Field readers return `_context_data_source[field]` → `nil` when unset,
  never raising. So forwarding works identically on an ok or failed child — on a failed child it
  forwards whatever the child managed to expose (the errors-bearing `user`) and `nil` for the rest.
- **Pure forwarding.** `expose(result)` never reads `ok?`/`error` and never calls `fail!`.
  Propagation stays the caller's explicit `fail! unless result.ok?` (or #109's base prefix). This
  is why it cannot reorder or mask the inner failure.
- **Empty intersection raises.** If the intersection is empty, `expose(result)` raises — this is
  always a wiring mistake (renamed field, wrong child). Crucially this is **safe and cannot mask a
  runtime inner failure**: the intersection is computed from *static* declared contracts on both
  sides, so it is identical on every code path regardless of whether the child succeeded or failed.
  An empty intersection means the code is mis-wired unconditionally, not that "the inner failed
  before exposing anything" (that scenario keeps a non-empty intersection and forwards `nil`s). The
  exact exception class is an implementation detail for the plan (a `ContractViolation` subclass).

### Detection robustness

Detection keys off `args.size == 1 && args.first.is_a?(Axn::Result)`. The other ways a `Result`
can appear in `expose` are unaffected: `expose(:child_result, some_result)` (two positional) and
`expose(child_result: some_result)` (kwargs) both still expose the `Result` *as a value*. Only the
lone-positional form — today an `ArgumentError` — changes meaning. `Axn::InternalContext` (the
inbound facade) is a different class and never triggers this path.

## `inputs` — resolved inbound fields, splattable

A new reader on the action instance returning a `Hash` of this action's **declared inbound fields**
mapped to their **resolved reader values** (post-`default`, post-`preprocess`), i.e. exactly what
the action's own readers see:

```ruby
def inputs
  self.class._declared_fields(:inbound).to_h { |f| [f, send_resolved(f)] }
end
```

(Exact resolution seam — reading through `internal_context` vs. the public readers — is for the
plan; the **requirement** is that values match what the action's readers return, so
`Child.call(**inputs)` forwards the same view the parent has, not raw `provided_data`.)

### Semantics & rules

- **Declared inbound only.** Undeclared passthrough keys in `provided_data` are *not* included, so
  they never leak into children.
- **Resolved values.** Defaults and preprocessing are applied — forwarding is faithful to the
  parent's own view.
- **Returns a plain `Hash`.** Subsetting needs no special API: `inputs.except(:role)`,
  `inputs.slice(:user, :company)`. Injection/override is just merge-at-call-site:
  `Child.call(**inputs.except(:role), role: ROLE)`.
- **Safe to splat into any child.** An action only validates its declared `expects` and ignores
  extra inbound keys (this is how `steps` already splats `__combined_data` into children), so
  forwarding a superset is harmless.

### Naming

`inputs` (chosen) over `expectations`:

- Names what it **returns** — resolved input *values* — whereas `expectations` reads as the
  *declarations*, not the values.
- `expectations` carries a strong RSpec/test-assertion connotation; `**expectations` at a call site
  misreads as test code.
- Splats and reads naturally: `call(**inputs, role: ROLE)`.
- It does **not** need to mirror `result`: the outbound side is a rich facade you *read*; the
  inbound side is a splattable bag of values you *forward* — different roles, different names.

### Reserved name

`inputs` becomes a reserved name for **expectations and exposures** (added to both
`RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` and `RESERVED_FIELD_NAMES_FOR_EXPOSURES`), so
`expects :inputs` / `exposes :inputs` raise at declaration rather than shadowing the reader. This is
consistent with Axn already reserving common nouns (`message`, `error`, `success`, `result`,
`outcome`). It is a (pre-1.0) breaking change for any action with an `inputs` field — call out in
CHANGELOG; sweep os-app for collisions before the gem bump.

## Interaction with PRO-2746 (#109)

These helpers assume the **non-bang `.call`** path (you need the `Result` object to forward from,
including on failure). The clean post-#109 facade is:

```ruby
error "Unable to create assignment"          # base — prefixes the propagated child failure
# …
result = Child.call(**inputs)
expose(result)
fail! unless result.ok?                       # bare fail! → base error is the message; no double-prefix
```

A bare `fail! unless result.ok?` (no message) lets the declared base `error` provide the message;
do **not** write `fail! result.error` alongside a base error or it double-prefixes.

## Rejected alternatives

- **`expose_from(result)` as a new verb.** Rejected: `expose`'s lone-positional slot is free
  (currently raises), the overload is unambiguous, and a single verb keeps the surface smaller.
- **Declarative `delegates_to Child, inject: { role: ROLE }`.** Rejected as the foundation: it
  reads well only for the trivial case and immediately needs escape hatches for the guard, the
  custom `success`, and the expose-then-fail ordering — re-creating `def call`. Viable later as
  sugar *over* these primitives.
- **`steps` / `step`.** Rejected: pipeline semantics fail-fast on a step failure and never forward
  the failing step's exposures, swallowing the `user.errors` the form needs.
- **`expectations` as the reader name.** Rejected in favor of `inputs` (see Naming).
- **Auto-forwarding all of `provided_data`.** Rejected: leaks undeclared passthrough keys into
  children and forwards raw rather than resolved values.

## Testing

- `expose(result)` forwards the declared-field intersection on an **ok** result.
- `expose(result)` forwards the errors-bearing field on a **failed** result, and `nil` for fields
  the child never exposed — no raise.
- `expose(result)` raises on empty intersection.
- `expose(result)` leaves the existing two-positional / kwargs / lone-non-`Result` behaviors intact
  (including exposing a `Result` *as a value* via the two-positional and kwargs forms).
- `inputs` returns declared-inbound-only, resolved (default/preprocess applied) values; excludes
  undeclared passthrough keys; round-trips through a child `.call(**inputs)`.
- `inputs.except`/`.slice` + merge override forward the expected subset.
- `expects :inputs` / `exposes :inputs` raise `ReservedAttributeError`.

## os-app follow-up

Once released and the gem is bumped, simplify the os-app#4945 facades
(`Mfp::Assignment::Create`, `Teamshares::Secondment::Create`) onto `**inputs` + `expose(result)` +
bare `fail!`, and sweep for any `expects/exposes :inputs` collisions before the bump.
