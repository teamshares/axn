# frozen_string_literal: true

require "axn"

module Axn
  # The supported testing surface. Separate from `axn/testing/spec_helpers`, which exists to be
  # `include`d into an RSpec config — a host app wanting only the reset should not have to load
  # RSpec-shaped helpers to get it.
  module Testing
    class << self
      # Drops axn's process-global DERIVED state, so one example's auto-detection cannot decide the
      # next one's behavior. Safe and idempotent in a `before` hook.
      #
      # Deliberately does NOT reset:
      #
      #   * `Axn.config` or `Axn::Extensions.config`. A host app configures axn once in an
      #     initializer, so resetting config here would silently un-configure every example after the
      #     first — presenting as unrelated failures deep in someone else's suite rather than as
      #     anything traceable to this call.
      #   * The registries (`Strategies`, `Async::Adapters`, `Mountable::MountingStrategies`). Their
      #     `clear!` restores built-ins and discards deliberate registrations, which is axn's own
      #     suite's business rather than a host app's.
      #   * `Tools::Registry`'s recorded action classes. That set accumulates every action class
      #     defined in the process, and clearing it mid-suite would make `Axn.tools_for` blind to
      #     classes that are still loaded.
      #   * `Tools::Registry`'s registered ADAPTERS. An adapter gem registers at file-load time
      #     (`require` runs once per process), so a registration dropped here can never be
      #     re-established within that process — a host app with any tool-adapter gem in its Gemfile
      #     would have `Axn.tools_for` (and every adapter lookup) fail after the first example.
      #   * `Async::Adapters::Sidekiq::AutoConfigure`'s registration flags (`registered?`,
      #     `middleware_registered?`, `death_handler_registered?`). Registering installs onto
      #     Sidekiq's actual global middleware chain and death-handler list once per process, so
      #     these flags are a record of that installation rather than state axn can regenerate.
      #     Clearing them here would make the record disagree with Sidekiq's real state — the
      #     middleware would still be installed, but `validate_configuration!` would read
      #     `middleware_registered?` as false and raise on the next job. Only its validation memo
      #     is dropped, via `reset_validation!`, so a spec that changes
      #     `Axn.config.async_exception_reporting` gets validation re-run against the new mode.
      #   * `Core::InstanceDeferral`'s record of which inherited methods it has already announced. The
      #     announcement is a log line already emitted, so re-arming it here would have a host app's suite
      #     re-decide a deferral the process already announced on that action's first run. Its private spec
      #     hook is for axn's own suite.
      #
      # Two further pieces of per-execution state need nothing here: Internal::ExceptionClassification
      # and Internal::CarriedPresentation both store in ActiveSupport::IsolatedExecutionState and are
      # already reset by NestingTracking when the outermost action finishes. A third needs nothing for
      # a different reason: the `axn.call` span reference (PRO-3278, `Internal::Tracing::SPAN_IVAR`)
      # lives as an ivar on the action INSTANCE, not in any process-global or IsolatedExecutionState
      # store, and the executor's own `ensure` (`Core::Executor#with_current_span`) clears it before
      # the call returns — there is no derived memo here for a reset to drop.
      def reset!
        Axn::Internal::Tracing.reset!
        Axn::Async::Adapters::Sidekiq::AutoConfigure.reset_validation! if defined?(Axn::Async::Adapters::Sidekiq::AutoConfigure)
        Axn::Core::NestingTracking._reset_isolation_warning!

        nil
      end
    end
  end
end
