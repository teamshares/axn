# `on_enqueue_all` — once-per-run fan-out summary hook

**Linear:** [PRO-2743](https://linear.app/teamshares/issue/PRO-2743/axn-pre-fan-out-summary-support)
**Date:** 2026-06-17
**Status:** Design approved, ready for implementation plan

## Problem

`enqueues_each` / `enqueue_all` fans out one isolated background job per record, but
gives the action no hook to run **once-per-run, batch-level work** around the fan-out.
Today that forces a hand-rolled parent/child wrapper action — the exact boilerplate
`enqueue_all` is meant to remove.

Motivating cases (from PRO-2735 worker conversions):

- **EOY tax reminders (PRO-2740):** post one Slack message to `:eng_ops` summarizing the
  resolved batch ("X active, Y deactivated users were potentially reminded") around the
  fan-out per tax profile. Requires inspecting the source records (active/deactivated split).
- **Buyback deferment (PRO-2737):** a lightweight "Found N events" summary. Just needs the count.

This ticket adds the affordance upstream in the `axn` gem. The PRO-2735 conversions are
**not blocked** on it — they ship with summaries dropped and adopt the hook in a follow-up.

## Solution overview

A declarative, once-per-run callback — `on_enqueue_all` — that fires **inside**
`EnqueueAllOrchestrator`, off the clock thread, **after** the fan-out loop completes.
It receives the exact enqueued `count:` and an honest `sources:` hash, and is wrapped so a
raising block can never abort the fan-out.

### DSL

Declared on the action, alongside `enqueues_each`, in `BatchEnqueue::DSL`:

```ruby
class StockCertificate::EoyTaxReminder
  include Axn
  async :sidekiq

  expects :tax_profile, model: TaxProfile
  enqueues_each :tax_profile, from: -> { TaxProfile.needs_address_validation }

  on_enqueue_all do |sources:, count:|
    active, inactive = sources[:tax_profile].partition { _1.user.active? }
    SlackSender.call(
      channel: :eng_ops,
      text: "#{active.size} active, #{inactive.size} deactivated users were potentially reminded (#{count} jobs enqueued)",
    )
  end

  def call
    # per-tax-profile work
  end
end
```

Count-only example (arity-flexible — take any subset of the kwargs, or none):

```ruby
on_enqueue_all { |count:| info "Found #{count} events" }
```

## Design decisions

### Timing: fires *after* the fan-out loop

The hook fires after `iterate` completes, not before. Rationale:

- The **only** quantity uniformly well-defined across single-source and multi-field
  cross-product runs is the exact enqueued `count` — and after the loop it is already
  computed (`count[:value]`). A "pre" hook could only offer `source.count`, which is
  **meaningless for a cross-product** (you'd be multiplying per-config counts, and a
  `filter_block` breaks even that).
- Neither motivating case needs a true pre-work heartbeat: EOY's summary reads fine in
  past tense, and "Found N" is satisfied by the exact post-filter count.

### Block receives `count:` (always) and `sources:` (honest hash)

- **`count:`** — exact post-filter enqueued total. Always passed. Uniform across single
  and cross-product runs.
- **`sources:`** — a hash `{ field => resolved_relation }` with one entry per config:
  - single config → `{ tax_profile: <relation> }`
  - cross-product → `{ user: <relation>, company: <relation> }`

  Each value is the config's **resolved but un-materialized** source (e.g. an AR relation),
  so the block can run its own efficient aggregate (`.count`, `.group`, `.partition` only
  if it opts in). Because `from:` lambdas are zero-arg, resolving once for the hook is
  exactly representative of what `iterate` uses.

  **Why a hash, not a scalar `source:`:** a singular `source:` would be `nil` (a lie) in
  the cross-product case. The hash is always honest. It also reflects kwarg overrides
  (`enqueue_all(tax_profile: SomeRelation)`) correctly, where a block re-referencing its
  own declared lambda would silently describe the wrong population.

  `sources` is resolved **only when at least one `on_enqueue_all` callback is registered**,
  so actions without the hook pay no extra query.

- **Flexible arity** via the gem's existing `Axn::Internal::Callable.only_requested_params`:
  a block may declare `|sources:|`, `|count:|`, `|sources:, count:|`, `|**opts|`, or no
  params at all. Same ergonomics as `on_success` et al.

### Storage & multiplicity

- Stored in `class_attribute :_enqueue_all_callbacks, default: []` — inherits to subclasses,
  same pattern as `_batch_enqueue_configs`.
- **Multiple `on_enqueue_all` declarations are allowed**, fired in declaration order —
  consistent with the `on_success`/`on_error`/`on_exception` callback family.

### Execution context: the target action *class*

Each block is `target.instance_exec(...)`-ed on the **target action class** (the class that
declared `on_enqueue_all`). This:

- gives the block class-level `log`/`info`/`warn` (Axn class-level logging),
- is semantically the user's own class, and
- works **identically in both the async and foreground paths**, since both have `target`
  in scope and neither instantiates the target action.

### Firing location: end of `execute_iteration` (covers both paths)

The hook fires at the end of `EnqueueAllOrchestrator.execute_iteration` (a class method),
after `iterate` and before returning the count. This single insertion point covers:

- the **async** path: `#call` → `execute_iteration` (orchestrator.rb:33), and
- the **foreground** path: `enqueue_for` → `execute_iteration_without_logging` →
  `execute_iteration` (orchestrator.rb:77 → 104), used when an iterable kwarg can't be
  serialized for background execution.

It does **not** fire on the degenerate no-`expects` single-job path (`enqueue_for`
short-circuits via `target.call_async` at orchestrator.rb:60) — there is no fan-out to
summarize. This is documented behavior.

### Error isolation: swallow, mirroring `on_success`

A raising `on_enqueue_all` block must **never** abort the fan-out (the fan-out is the
important work, and at this point it has already completed — there is nothing to roll back).

Each block invocation is wrapped in `Axn::Internal::PipingError.swallow`, exactly like the
sibling `filter_block` (orchestrator.rb:279–289) and the `on_success`/`on_error` callbacks
(which pipe through `Invoker` → `PipingError.swallow`). Behavior:

- **Production / test:** swallowed + `logger.warn`.
- **Development:** re-raised **only if** `Axn.config.raise_piping_errors_in_dev` is enabled.

We deliberately do **not** route to `Axn.config.on_exception` (Honeybadger): the enqueue
has already succeeded, so reporting it as an exception would falsely read as "the job
failed," breaking consistency with the rest of the callback family. A raise here cannot
change the enqueue outcome — same contract as `on_success`. Users who need stronger
guarantees rescue inside their own block.

A raise in one block does not prevent the remaining registered blocks from firing.

## Affected files (gem)

- `lib/axn/async/batch_enqueue.rb` — add the `on_enqueue_all` DSL method and the
  `_enqueue_all_callbacks` class attribute.
- `lib/axn/async/enqueue_all_orchestrator.rb` — fire the registered callbacks at the end
  of `execute_iteration`, resolving the `sources` hash (only when callbacks exist).

## Testing

- `spec/axn/async/batch_enqueue_spec.rb` (non-Rails) — DSL registration, multiplicity,
  arity flexibility, count correctness, `sources` hash shape (single + cross-product),
  error isolation (swallow + continue, remaining blocks still fire), no-fire on the
  no-`expects` path.
- `spec_rails/` dummy app — adoption-shaped coverage where a real AR relation / `find_each`
  source is needed (e.g. `sources[:field].partition`), confirming un-materialized relations
  and override-correctness.

(`spec/` is non-Rails; AR/Rails constants must stay guarded. Rails-dependent behavior lives
in `spec_rails/`.)

## Out of scope

- Post-job-**completion** hooks (would require integrating each backend's lifecycle to know
  when individual jobs finish). This hook fires when enqueueing completes, not when the
  fanned-out jobs complete.
- A pre-fan-out heartbeat firing *before* iteration.
- Auto-bumping os-app's lockfile. Per gem-release convention, a human batches the release;
  os-app adoption (PRO-2740, PRO-2737, and the audit-for-benefit callsites) lands as a
  follow-up after the gem ships.
