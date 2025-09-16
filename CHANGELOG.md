# Changelog

## Unreleased
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

## 0.1.0-alpha.2.8.1
* [BUGFIX] Fixed symbol callback and message handlers not working in inherited classes due to private method visibility issues
* [BUGFIX] `default_error` and `default_success` are now properly available for before hooks

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
