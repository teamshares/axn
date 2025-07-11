# Changelog

## Unreleased
* N/A
* More aggressive logging of swallowed exceptions when not in production mode
* Make automatic pre/post logging more digestible

## 0.1.0-alpha.2.5.2
* [BREAKING] Removing `EnqueueAllInBackground` + `EnqueueAllWorker` - better + simply solved at application level
* [TEST] Expose spec helpers to consumers (add `require "axn/testing/spec_helpers"` to your `spec_helper.rb`)
# [FEAT] Added ability to use custom Strategies (via e.g. `use :transaction`)

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
