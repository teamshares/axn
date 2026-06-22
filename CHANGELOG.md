# Changelog

## Unreleased
* [BREAKING] `on_success` now fires after the **enclosing** transaction commits (immediately when none is open) and is **skipped on rollback**, rather than always firing inline. Previously, an action nested inside another action's transaction ran its `on_success` before the outer transaction committed — so the side effect (email, HTTP call, enqueue) fired even when the outer transaction later rolled back. Implemented via `ActiveRecord.after_all_transactions_commit` (requires ActiveRecord 7.2+; no-op/inline without ActiveRecord). Nested `on_success` callbacks fire child-first; note that an outer action's `after` hooks now run before an inner action's `on_success`. Failure-path callbacks (`on_failure`/`on_error`/`on_exception`) are unaffected and still fire immediately. No opt-out flag. Caveat: deferral tracks **joinable** transactions only (the `transaction` strategy and ordinary `ActiveRecord::Base.transaction` blocks); an action run directly inside an explicitly non-joinable transaction (`joinable: false`) runs `on_success` immediately, since Rails hides such transactions from `after_all_transactions_commit`.
* [FEAT] Async argument serialization now uses `ActiveJob::Arguments` whenever ActiveJob is loaded — for **all** adapters, including Sidekiq. Within a deployment every backend now round-trips the same rich type set losslessly (GlobalID models, `Date`, `Time`, `DateTime`, `TimeWithZone`, `Duration`, `BigDecimal`, `Symbol`, `Range`, nested symbol-keyed hashes), fixing a latent bug where a Sidekiq-enqueued `expects :at, type: Time` arrived on the worker as a `String` (validation then failed) while the same action worked under the ActiveJob adapter. The one remaining asymmetry is documented: a deployment **without** ActiveJob accepts only JSON-native + GlobalID-able args (it has no rich serializer to use). `enqueue_all` static args follow the same rules — rich types round-trip on the ActiveJob path, JSON-native + GlobalID-able on the fallback (otherwise raising `UnserializableArgument`).
* [BUGFIX] Enqueuing an async action with an unserializable argument now raises a field-aware `Axn::Async::UnserializableArgument` (naming the field, its class, and the fix) at enqueue time — on both the ActiveJob path (wrapping `ActiveJob::SerializationError`) and the no-ActiveJob fallback path — instead of silently corrupting it (Sidekiq would JSON-stringify a `Symbol`/`Date`/`Time`, or dump a `Tempfile`/custom object into the payload).
* [BREAKING] The Sidekiq async payload format changed for the rich types above (ActiveJob's `_aj_*` tagging instead of the previous `_as_global_id` suffix / raw JSON values). Jobs enqueued before deploying this change and run after it may fail to deserialize — drain the Sidekiq queue across the deploy. The no-ActiveJob fallback wire format (`_as_global_id` suffix for GlobalID args) is unchanged. Separately, the fallback path now **raises** on `Symbol`/`Date`/`Time`/`BigDecimal`/files/custom objects that previously passed through (lossily); pass JSON-native or GlobalID-able values, or load ActiveJob for the richer set.
* [FEAT] `model:` `expects` fields now also define a `<field>_id` reader whose single meaning is the record's primary key — whether the action was called with `user:` or `user_id:`, `user_id` returns the pk. It triggers no extra lookup: for the default `:find` finder a supplied id is returned as-is; otherwise it reads the (memoized) resolved record's `.id`, so it's meaningful even with a custom finder (where the `<field>_id` key holds a lookup token, `user_id` still returns the actual pk). Alias-aware (`as: :raw_user` → `raw_user_id`) and silently defers (debug-logged) to any same-named method already declared. Composite primary keys aren't supported by the singular convention.
* [BREAKING] For the default `:find` finder, passing **both** a `model:` record and a contradictory `<field>_id` (e.g. `user: <id=5>, user_id: 9`) now raises `InboundValidationError` instead of silently preferring the record. Passing one, or both in agreement, is unchanged. Skipped for custom finders (the `<field>_id` value there is a lookup token, not a pk). Surfaces previously-silent contradictory input as a dev-facing failure.
* [FEAT] Add `as:` / `prefix:` to `expects` to rename the generated reader independently of the wire key. `expects :channel, as: :raw_channel` keeps `channel` as the caller-facing contract (validation, required-inputs, logging, sensitive filtering all still key off it) while exposing the value as `raw_channel` — freeing the field's name so you can define your own method (`def channel = Channel.find(raw_channel)`). `as:` renames a single field; `prefix:` is sugar that renames several at once via literal concatenation (`expects :id, :type, on: :event_params, prefix: :event_` → `event_id`, `event_type`), handy for unwrapping subfields. `as:`/`prefix:` can't be combined, used with `readers: false`, or applied to a dotted `on:` path; the renamed reader clears the same reserved-name/collision checks as a field. Composes with `model:` (the record — including the `<field>_id` lookup — resolves against the wire key and is exposed under the alias). Subfields declared `on:` a renamed parent reference it by its reader name (the alias). Not added to `exposes` (no instance reader to free; output naming is already covered by `expose`, `expose_return_as:`, and strategy options).
* [FEAT] Add `on_enqueue_all` — a declarative, once-per-run callback for `enqueues_each`/`enqueue_all` fan-out. It fires inside the orchestrator after the fan-out loop completes (off the clock thread), receiving the exact enqueued `count:` and an honest `sources:` hash, with flexible arity (declare a block taking neither, either, or both). The block is error-isolated — a raising callback can never abort the fan-out. Removes the hand-rolled parent/child wrapper action previously needed for batch-level summary work (e.g. posting one Slack summary around a per-record fan-out).
* [BREAKING] A nested `call!` failure now re-raises the inner action's original exception, identical to a top-level `call!` (previously: a fresh `Axn::Failure` wrapping the inner's `result.error` with a `source:` pointer and `cause:`). `Axn::Failure` now means exactly "`fail!` was called" everywhere. `Axn::Failure#source` is removed. To reshape a child's error with context, run the child with non-bang `call` and `fail!("context: #{result.error}") unless result.ok?`. An unhandled exception that propagates through nested `call!`s is now reported to `Axn.config.on_exception` **once** — at the innermost executor that classifies it as a reportable exception — rather than once per nesting level (each action's own `on_exception` callback still fires at its level). A `fails_on` classification is now **sticky** to the exception object: an exception an inner action reclassified as an expected failure stays a failure (fires `on_failure`, never reported, `result.outcome` is `failure`) even when bubbled up via `call!` to an ancestor that doesn't share that `fails_on` — so `fails_on` suppresses the report on the `call!` path too, not just `call`. The classification is per-object, so an unrelated same-class exception raised elsewhere remains a reportable exception.
* [BREAKING] Removed `error from:` and the per-message `prefix:` option on `error`/`success`. Use a declared base `error "…"` (prefixes failure reasons by default — see the prefixing FEAT entry) and the explicit `call` + `fail!` idiom for cross-action message shaping. Passing `from:`/`prefix:` now raises at declaration with the migration hint.
* [INTERNAL] `step` no longer uses `error from:` / the nested `call!` wrapping; it runs each child via `call` and `fail!`s with the step's `error_prefix:` (default `"<name>: "`). A parent orchestrator that declares a base `error` now has it cascade into step failures.
* [FEAT] A declared base `error "…"` now prefixes the action's specific failure *reasons* — conditional `error … if:`, dynamic `error` blocks, and `fail!` messages — rendered as `"<base><delimiter><reason>"`. Prefixing is on by default for reasons (`prefixed: true`) and **gated by a declared base** (no base ⇒ reasons render standalone, unchanged). Opt a single reason out with `prefixed: false` (on the declaration or on `fail!`). The join string is `delimiter:` on the base (default `": "`). `success`/`done!` mirror this. A static unconditional `error` is the base and is never itself prefixed (`prefixed: true` on it raises at declaration); `error(prefixed: true, &:message)` is the unconditional-dynamic detail form. Note: `result.error` returns the **prefixed** presentation string — `Axn::Failure#message` (seen when rescuing from `call!`) carries the raw reason without the prefix. **Behavior change for existing actions:** any action that already pairs a static `error`/`success` declaration with a conditional or dynamic one will see the conditional/dynamic message gain the base prefix by default — opt out with `prefixed: false` on the conditional/dynamic declaration.
* [FEAT] `success`/`done!` now support the same base-prefix semantics as `error`/`fail!`. A static unconditional `success "Headline"` declaration becomes the base; conditional or dynamic `success` entries are treated as prefixed reasons rendered as `"Headline: reason"`. `done!("message")` is prefixed by the base by default; `done!("message", prefixed: false)` opts out. When no base is declared the behavior is unchanged.
* [FEAT] Add `use :model` strategy — the ActiveRecord sibling of `use :form`. Standardizes "build/find a model, apply attributes, save, settle validation failures cleanly" actions: `use :model, create: Widget` / `update: :widget` / `as: :widget` (upsert). Auto-declares the contract (`expects :params` + the `model: true` field, respecting a pre-declared one), exposes the record (under the field name, or `result.model` when unnamed), and saves it in a `before` hook (`fail! unless record.save`) so `call` is free for post-save logic. Attributes come from an overridable `model_params` (defaults to `params`; must return a plain Hash or *permitted* params — unpermitted `ActionController::Parameters` raise an actionable error rather than silently bypassing mass-assignment protection), with `inject:` sugar for merging context fields (explicit `model_params` keys win on collision). An optional `prepare_model(record)` hook gives imperative pre-save tweaks (nested associations, derived fields) a home — it runs after attribute assignment and always before the gated save. Ships mode-aware default messages ("Created/Updated <Model>" + the model's validation errors); declare a base `error "…"` after `use :model` to prefix the validation body, and any other override (custom `success`/`error`/`fails_on`) is a normal DSL declaration after `use :model`. Wires `fails_on ActiveRecord::RecordInvalid` as a safety net; does not auto-wrap `use :transaction` (compose it explicitly when needed). Requires ActiveRecord (raises `NotImplementedError` at declaration if it isn't loaded, mirroring `use :transaction`).
* [FEAT] Add `fails_on` declaration to reclassify chosen exception classes from the **exception** outcome into the **failure** outcome. A matching raised exception now settles as a failed result — firing `on_failure` (not `on_exception`) and skipping the global `Axn.config.on_exception` report (on both sync and async/discarded-job paths) — **without** wrapping it in `Axn::Failure`, so `result.exception` keeps the original and the existing `error` message resolution is unchanged. Rides `fail!`/`error` muscle memory: `fails_on ActiveRecord::RecordInvalid, "Unable to submit"`, a block receiving the exception, or an array of classes. Gives routine validation failures a declarative path out of the global handler without a manual `rescue … fail!`. Documented as the supported pattern for suppressing spurious `on_exception` reports when an inner action raises an expected error that an outer action handles — declare `fails_on` on the inner action (the one that knows the exception is expected), not on the outer.
* [INTERNAL] Namespaced the framework's internal instance variables on the action instance (`@result` → `@__result`, `@internal_context` → `@__internal_context`) and the class-level `@inspection_filter` → `@__inspection_filter`, so a user assigning their own `@result`/`@internal_context` inside an action can no longer clobber exposed-value extraction or message rendering. The unrelated `@result` memo on the internal `DiscardedJobAction` proxy was renamed `@discarded_job_result` to avoid conflating it with the facade. No public API change — the `result` / `internal_context` methods are unchanged.

## 0.1.0-alpha.4.3
* [FEAT] Plain namespace **modules** can now host mounted actions: `include Axn::Mountable` on a module (not just a class) exposes `mount_axn` / `mount_axn_method` / `step`. Class hosts keep the existing `class_attribute` + `inherited` behavior; module hosts use singleton accessors and skip the `inherited` hook (modules have no subclasses). Also fixes a `.name` clobber so passing an already-named class to `mount_axn` preserves its original name instead of rewriting it to the `Axns` namespace path.
* [BUGFIX] Fixed an off-by-one in `async.attempt` reported from the Sidekiq death handler: Sidekiq increments `retry_count` before invoking death handlers, so an exhausted `retry: 3` job (4 executions) reported attempt `5` instead of `4`. The bug was metadata-only — control flow (`retries_exhausted?`, `first_attempt?`, `should_trigger_on_exception?`) was unaffected. Also documents why framework-native integrations (e.g. Honeybadger's Sidekiq plugin) can produce duplicate async error reports, with a tag-and-filter suppression recipe.
* [BUGFIX] Subfield names that collide with a method on the parent value (e.g. `zip`, `count`, `first` — any `Hash`/`Enumerable` method) are now read as keys instead of being dispatched as method calls. Previously `expects :zip, on: :address` extracted `address.zip` (`Enumerable#zip`) and failed with a bogus error; `FieldResolvers::Extract` now digs the key first for Hash-like sources and only falls back to a reader method for non-diggable objects (e.g. `Data` instances).
* [FEAT] `expects … on:` now accepts a **dotted path** to reach a deeply-nested parent (e.g. `expects :zip, on: "address.billing", type: String` validates `address[:billing][:zip]` and defines a flat `zip` reader). The root segment must be a declared field/subfield. `default:`/`preprocess:`/`sensitive:` combined with a dotted `on:` raise `ArgumentError` (writing into — and redacting — an arbitrary nested path isn't supported yet); single-key `on:` is unchanged.
* [FEAT] Add block syntax for declaring the per-member shape of a structured field on `expects`/`exposes`. On a `type: Array`, `type: Hash`, or class-typed field, a block declares member contracts: `expects :items, type: Array do field :status, type: String, inclusion: { in: %w[a b] } end`. Members accept the same options as top-level fields (`type`, `inclusion`, `optional`, `description`, …) and recurse via nested blocks. For arrays each element is validated with indexed errors (`element at index 2: status …`); for a single Hash/object value its members are validated directly. The block requires a single structured `type:` (raises `ArgumentError` on scalars, unions, or no type), composes with `of:` (which still checks element class), and — unlike `on:` subfields — defines **no** reader methods. Downstream tooling reads members from `config.validations[:shape][:members]`.
* [FEAT] Add `of:` array-element validation for `expects`/`exposes`. On a `type: Array` field, `of:` validates each element: a single class (`of: String`), a union (`of: [String, Numeric]` — an element passes if it matches *any*), the `:boolean`/`:uuid`/`:params` symbols, or a `Data.define` class. Only valid alongside `type: Array` (raises `ArgumentError` otherwise, including for unions like `type: [Array, String]`). Error messages report the failing element's index (e.g. `element at index 2 is not a String`) and honor a custom `message:`. `optional`/`allow_blank`/`allow_nil` govern whether the whole field may be absent — they do not make individual elements blank-able. Downstream tooling can read the element type from `config.validations[:of][:klass]`.
* [FEAT] `exposes`-declared fields that are also `expects`-declared are now auto-copied from the input into the result on **all** outcome paths — success, `done!`, `fail!`, and unhandled exception. Previously, the auto-copy only ran on success/`done!` paths, leaving `result.field` as `nil` after `fail!` or an exception even when the field was provided as input. This is particularly useful for re-exposing mutated ActiveRecord objects (e.g. inspecting `user.errors` after a failed save). Explicit `expose` calls before a failure continue to work and take precedence.
* [FEAT] Execution log messages now display elapsed time in human-readable units (milliseconds, seconds, minutes, or hours) instead of always showing milliseconds
* [BREAKING] `exposes` no longer defines a direct reader method on the action instance. Exposed fields must be accessed via `result.field` (e.g., `result.greeting`). `expects` readers are unaffected. User-defined methods with the same name as an exposed field are preserved (DefaultCall still calls them). Use `result.field` in `success`/`error` message callables and `sensitive:` procs to access output values.
* [FEAT] Add boolean predicate readers for `expects` and `exposes`: `expects :enabled, type: :boolean` defines `enabled?` on the action instance; `exposes :enabled, type: :boolean` defines `result.enabled?`.
* [BUGFIX] `ExceptionContext.build` no longer raises `URI::GID::MissingModelIdError` when an exposed or expected value is an unpersisted ActiveRecord record. The formatter now renders such values as `#<ClassName (unpersisted)>` and the optional retry command falls back to `inspect` instead of generating `Model.find(nil)`.
* [FEAT] Add dynamic `sensitive:` option support for `expects` and `exposes` fields - accepts procs or symbols that are evaluated at runtime against the action instance, allowing conditional sensitivity based on input values (e.g., `exposes :data, sensitive: -> { redact_mode }`)

## 0.1.0-alpha.4.2
* [FEAT] Add extensible field metadata support for `expects`/`exposes`:
  * **New** `Axn.extension_config` registry for library-facing configuration (separate from app-facing `Axn.config`)
  * **New** `description:` metadata option for field declarations (e.g., `expects :name, description: "The user's name"`)
  * **New** `FieldConfig#metadata` and `SubfieldConfig#metadata` attributes with `#description` accessor
  * **New** `Axn.extension_config.register_field_metadata_key(:key)` for wrapper gems to register custom metadata keys
  * **New** Unknown validation keys now raise `ArgumentError` (catches typos like `nummericality:`)
  * **New** Metadata can only be provided when declaring a single field (multi-field + metadata raises `ArgumentError`)
* [FEAT] Add `readers:` option validation: `readers: false` now raises `ArgumentError` when used without `on:` (only valid for subfields)
* [BUGFIX] `set_default_async(:sidekiq)` now properly triggers `AutoConfigure.register!`
* [BREAKING] Refactored context API for exception reporting and handlers:
  * **Removed** `context_for_logging(direction)` instance method
  * **Added** public `execution_context` method returning structured hash: `{ inputs: {...}, outputs: {...}, **extra_keys }`
  * **Added** private `inputs_for_logging` / `outputs_for_logging` methods for automatic pre/post logging (do NOT include extra context)
  * **Renamed** `set_logging_context` → `set_execution_context`, `clear_logging_context` → `clear_execution_context`, hook `additional_logging_context` → `additional_execution_context`
  * **Reserved keys:** `:inputs` and `:outputs` cannot be set via `set_execution_context` or the hook—they always come from the action's contract
  * **Internal:** Class method `context_for_logging(data:, direction:)` renamed to `_context_slice(data:, direction:)`
  * Exception context now includes both `inputs` and `outputs` with additional context merged at the top level (not nested inside `inputs`)

## 0.1.0-alpha.4.1
* [BREAKING][BUGFIX] `fail!` in async jobs no longer triggers retries - business logic failures complete without retry (Sidekiq and ActiveJob adapters)
* [FEAT] Add `async_exception_reporting` config to control when `on_exception` triggers in async context (`:every_attempt`, `:first_and_exhausted`, `:only_exhausted`)
* [FEAT] Add retry context to `on_exception` calls in async jobs - includes attempt number, max retries, exhausted status, and job ID
* [INTERNAL] ActiveJob adapter now uses `after_discard` callback (Rails 7.1+) to properly report discarded jobs including `discard_on` exceptions and exhausted retries
* [FEAT] Add ability for individual actions to override global `async_exception_reporting`

## 0.1.0-alpha.4
* [FEAT] Action class constants are now created eagerly when child classes inherit from parents with mounted actions, allowing direct constant access (e.g., `TeamsharesAPI::Company::Axns::Get.call`)
* [FEAT] Add ability to determine if currently running in background
* [FEAT] Handle done! and fail! while executing user blocks
* [BREAKING] `emit_metrics` hook now receives keyword arguments (`resource:`, `result:`) instead of positional arguments
* [FEAT] Default `call` method automatically exposes declared exposures by calling methods with matching names - you can now omit `call` entirely when you only need to expose values from private methods
* [BREAKING] Rename `auto_log` -> `log_calls`
* [FEAT] Add `log_errors`
* [FEAT] Add `raise_piping_errors_in_dev` config option to raise framework errors in dev only
* [BREAKING] Convert profiling from `profile` method to `use :vernier` strategy - profiling now only captures hooks and user code (excludes framework overhead like tracing, logging, timing)
* [FEAT] Add `set_logging_context` and `additional_logging_context` hook to inject additional context into exception logging
* [FEAT] Added ActiveSupport::Notification emission for `axn.call_async` (separate from `axn.call`) - emits notification when async jobs are enqueued with payload including resource, action_class, kwargs, and adapter name
* [INTERNAL] Refactored async adapters to use template method pattern - adapters now implement `_enqueue_async_job` hook instead of overriding `call_async`, eliminating duplication of notification and logging logic
* [FEAT] Enhanced `error from:` to support arrays of child classes and `from: true` to match any child action - prefix is now optional when using `from:`
* Improve handling of _async options to call_async (bugfix + serialization improvements)
* [BREAKING] Replace `enqueue_all_via` block with new `enqueues_each` DSL (now in `Axn::Async`) - declarative batch enqueueing for background job processing

## 0.1.0-alpha.3
* [FEAT] Added Vernier profiling support with `profile if:` conditional interface and `Axn.config.profiling` configuration
* [FEAT] Extended model validation to support custom finder methods with `expects :user, model: { klass: User, finder: :find }` syntax
* [BREAKING] Removed `#try` method
* [BREAKING] Removed `Axn()` method sugar (use `Axn::Factory.build` directly)
* [BREAKING] Renamed `Action::Configuration` + `Action.config` -> `Axn::Configuration` + `Axn.config`
* [BREAKING] Move `Axn::Util` to `Axn::Internal::Logging`
* [BREAKING] !! Move all `Action` to `Axn` (notably `include Action` is now `include Axn`)
* [FEAT] Continues to support plain ruby usage, but when used alongside Rails now includes a Rails Engine integrate automatically (e.g. providing generators).
  * Added Rails generator `rails generate axn Some::Action::Name foo bar` to create action classes with expectations
  * Autoload actions from `app/actions` (add config.rails.app_actions_autoload_namespace to allow setting custom namespace)
* [INTERNAL] Clearer hooks for supporting additional background providers in the future
* [BREAKING] spec_helpers: removed rarely used `build_axn`; renamed existing `build_action` -> `build_axn`
* [FEAT] `Axn::Factory.build` can receive a callable OR a block
* [FEAT] Added `#finalized?` method to `Axn::Result` to check if result has completed execution
* [FEAT] Added `type: :params` validation option for `expects`/`exposes` that accepts Hash or ActionController::Parameters (Rails-compatible)
* [FEAT] Allow validations to access instance methods (e.g. `inclusion: { in: :some_method }`)
* [FEAT] Allow message `prefix` to invoke callables/method name symbols the same way e.g. `if` does
* [BREAKING] `default`s for `expects` and `exposes` are only applied to explicitly `nil` values (previous applied if given value was blank, which caused bugs for boolean handling)
* [FEAT] Support `sensitive: true` on subfields (with `on:`)
* [FEAT] Support `preprocess` on subfields (with `on:`)
* [FEAT] Support `default` on subfields (with `on:`)
* [FEAT] Added `#done!` method for early completion with success result
* [FEAT] Extended `#fail!` and `#done!` methods to accept keyword arguments for exposing data before halting execution
* [INTERAL] Renamed `Axn::Enqueueable` to `Axn::Async`
* [BREAKING] Replaced `.enqueue` (only supported sidekiq) with `.call_async` (via a configurable registry of backgrounding libraries)
* [FEAT] attachable now creates a foo_async to call call_async
* `type` validator is not still applied to the blank value when allow_blank is true (`type: Hash` will no longer accept `false` or `""`)
* [FEAT] `expects`/`exposes` now prefers new `optional: true` over allow_blank for simplicity
* [FEAT] `Axn::Result` now supports Ruby 3's pattern matching feature
* [FEAT] Extended attachable functionality: added `mount_axn_method` for creating class methods that return values directly instead of wrapped in `Axn::Result`
* [Internal] Replaced `Axn::Attachable` with `Axn::Mountable` - complete refactor of action mounting system
  * [BREAKING] `#axn` → `#mount_axn` for method mounting
  * [BREAKING] `#axn_method` → `#mount_axn_method` for direct method mounting
  * [NEW] `enqueue_all_via` - Mount batch enqueueing functionality for background job processing
* [FEAT] Enhanced async execution with job scheduling support
  * [NEW] Support for scheduled async jobs via `_async` parameter with `wait_until:` and `wait:` options
  * [NEW] `enqueue` shortcut methods for all mounted actions

## 0.1.0-alpha.2.8.1
* [BUGFIX] Fixed symbol callback and message handlers not working in inherited classes due to private method visibility issues
* [BUGFIX] `default_error` and `default_success` are now properly available for before hooks
* [FEAT] Support scheduling async jobs (via new `_async` key)

## 0.1.0-alpha.2.8
* [FEAT] Custom RuboCop cop `Axn/UncheckedResult` to enforce proper result handling in Actions with configurable nested/non-nested checking
* [FEAT] Added `prefix:` keyword support to `error` method for customizing error message prefixes
  * When no block or message is provided, falls back to `e.message` with the prefix
* [BREAKING] `result.outcome` now returns a string inquirer instead of a symbol
* [BREAKING] **Message ordering change**: Static success/error messages (without conditions) should now be defined **first** in your action class, before any conditional messages. This ensures proper fallback behavior and prevents conditional messages from being shadowed by static ones.
* [CHANGE] `result.exception` will new return the internal Action::Failure, rather than nil, when user calls `fail!`
* [BREAKING] `hoist_errors` has been replaced by `error from:`
* [FEAT] Improved Axn::Factory.build support for newly-added messaging and callback descriptors

## 0.1.0-alpha.2.7.1
* [FEAT] Implemented symbol method handler support for callbacks

## 0.1.0-alpha.2.7
* [BREAKING] Replaced `messages` declaration with separate `success` and `error` calls
* [BREAKING] Removed `rescues` method (use `error_from` for custom error messages; all exceptions now report to `on_exception` handlers)
* [BREAKING] Replaced `error_from` with an optional `if:` argument on `error`
  * [FEAT] Implemented conditional success message filtering as well
* [FEAT] Added block support for `error` and `success`
* [FEAT] `if:` now supports symbol predicates referencing instance methods (arity 0, 1, or keyword `exception:`). If the method accepts `exception:` it is passed as a keyword; else if it accepts one positional arg, it is passed positionally; otherwise it is called with no args. If the method is missing, the symbol falls back to constant lookup (e.g., `:ArgumentError`).
* [FEAT] `success`/`error` now accept symbol method names (e.g., `success :local_method`). Handlers can receive the exception via keyword (`exception:`) or single positional argument; otherwise they are called with no args.
* [BREAKING] Updated callback methods (`on_success`, `on_error`, `on_failure`, `on_exception`) to use consistent `if:` interface (matching messages)
* [FEAT] Added `unless:` support to both `success`/`error` messages and callbacks (`on_success`, `on_error`, `on_failure`, `on_exception`)

## 0.1.0-alpha.2.6.1
* [FEAT] Added `elapsed_time` and `outcome` methods to `Action::Result`
  * `elapsed_time` returns execution time in milliseconds (Float)
  * `outcome` returns execution outcome as symbol (`:success`, `:failure`, or `:exception`)
* [BREAKING] `emit_metrics` hook now receives the full `Action::Result` object instead of just the outcome
  * Provides access to both outcome and elapsed time for richer metrics
  * Example: `proc { |resource, result| TS::Metrics.histogram("action.duration", result.elapsed_time) }`
* [BREAKING] Replaced `Action.config.default_log_level` and `default_autolog_level` with simpler `log_level`
* [BREAKING] `autolog_level` method overrides with e.g. `auto_log :warn` or `auto_log false`
* [BREAKING] Direct access to exposed fields in callables no longer works -- `foo` becomes `result.foo`
* [BREAKING] Removed `success?` check on Action::Result (use `ok?` instead)
* [FEAT] Added callback and strategy support to Axn::Factory.build

## 0.1.0-alpha.2.6
* Inline interactor code (no more dependency on unpublished forked branch to support inheritance)
  * Refactor internals to clean implementation now that we have direct control
  * [BREAKING] Replaced `Action.config.top_level_around_hook` with `.wrap_with_trace` and `.emit_metrics`
  * [BREAKING] the order of hooks with inheritance has changed to more intuitively follow the natural pattern of setup (general → specific) and teardown (specific → general):
    * **Before hooks**: Parent → Child (general setup first, then specific)
    * **After hooks**: Child → Parent (specific cleanup first, then general)
    * **Around hooks**: Parent wraps child (parent outside, child inside)
* Removed non-functional #rollback traces (use on_exception hook instead)
* Clean requires structure

## 0.1.0-alpha.2.5.3.1
* Remove explicit 'require rspec' from `axn/testing/spec_helpers` (must already be loaded)

## 0.1.0-alpha.2.5.3
* More aggressive logging of swallowed exceptions when not in production mode
* Make automatic pre/post logging more digestible

## 0.1.0-alpha.2.5.2
* [BREAKING] Removing `EnqueueAllInBackground` + `EnqueueAllWorker` - better + simply solved at application level
* [TEST] Expose spec helpers to consumers (add `require "axn/testing/spec_helpers"` to your `spec_helper.rb`)
* [FEAT] Added ability to use custom Strategies (via e.g. `use :transaction`)

## 0.1.0-alpha.2.5.1.2
* [BUGFIX] Subfield expectations: now support hashes with string keys (using with_indifferent_access)
* [BUGFIX] Subfield expectations: Model reader fields now cache initial value (otherwise get fresh instance each call, cannot make in-memory changes)

## 0.1.0-alpha.2.5.1.1
* [BUGFIX] TypeValidator must handle anonymous classes when determining if given argument is an RSpec mock

## 0.1.0-alpha.2.5.1
* Added new `model` validator for expectations
* [FEAT] Extended `expects` with the `on:` key to allow declaring nested data shapes/validations

## 0.1.0-alpha.2.5
* Support blank exposures for `Action::Result.ok`
* Modify Action::Failure's initialize signature (to better match StandardError)
* Reduce reserved fields to allow some `expects` (e.g. `message`) that would shadow internals if used as `exposes`
* Default logging changes:
  * Add `default_log_level` and `default_autolog_level` class methods (so inheritable) via `Action.config`
  * Remove `global_debug_logging?` from Configuration + unused `SA_DEBUG_TARGETS` approach to configuring logging
* Improved testing ergonomics: the `type` expectation will now return `true` for _any_ `RSpec::Mocks::` subclass
* Enqueueable improvements:
  * Extracted out of Core
  * Renamed to `Enqueueable::ViaSidekiq` (make it easier to support different background runners in the future)
  * Added ability to call `.enqueue_all_in_background` to run an Action's class-level `.enqueue_all` method (if defined) on a background worker
    (important if triggered via a clock process that is NOT intended to execute actual jobs)
* Restructure internals (call/call! + run/run! + Action::Failure) to simplify upstream implementation since we always wrap any raised exceptions

## 0.1.0-alpha.2.4.1
* [FEAT] Adds full suite of per-Axn callbacks: `on_exception`, `on_failure`, `on_error`, `on_success`

## 0.1.0-alpha.2.4
* [FEAT] Adds per-Axn `on_exception` handlers

## 0.1.0-alpha.2.3
* `expects` / `exposes`: Add `type: :uuid` special case validation
* [BUGFIX] Allow `hoist_errors` to pass the result through on success (allow access to subactions' exposures)
* [`Axn::Factory`] Support error_from + rescues
* `Action::Result.error` spec helper -- creation should NOT trigger global exception handler
* [CHANGE] `expects` / `exposes`: The `default` key, if a callable, should be evaluated in the _instance_'s context

## 0.1.0-alpha.2.2
* Expands `Action::Result.ok` and `Action::Result.error` to better support mocking in specs

## 0.1.0-alpha.2.1
* Expects/Exposes: Add `allow_nil` option
* Expects/Exposes: Replace `boolean: true` with `type: :boolean`
* Truncate default debug line at 100 chars
* Support complex Axn::Factory configurations
* Auto-generate self.class.name for attachables

## 0.1.0-alpha.2
* Renamed `.rescues` to `.error_from`
* Implemented new `.rescues` (like `.error_from`, but avoids triggering on_exception handler)
* Prevented `expect`ing and `expose`ing fields that conflict with internal method names
* [Action::Result] Removed `failure?` from public interface (prefer negating `ok?`)
* Reorganized internals into Core vs (newly added) Attachable
* Add some meta-functionality: Axn::Factory + Attachable (subactions + steps support)

## 0.1.0-alpha.1.1
* Reverted `gets` / `sets` back to `expects` / `exposes`

## 0.1.0-alpha.1
* Initial implementation
