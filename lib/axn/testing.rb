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
      #
      # Two further pieces of per-execution state need nothing here: Internal::ExceptionClassification
      # and Internal::CarriedPresentation both store in ActiveSupport::IsolatedExecutionState and are
      # already reset by NestingTracking when the outermost action finishes.
      def reset!
        Axn::Internal::Tracing.reset!
        Axn::Async::Adapters::Sidekiq::AutoConfigure.reset! if defined?(Axn::Async::Adapters::Sidekiq::AutoConfigure)
        Axn::Core::NestingTracking._reset_isolation_warning!
        Axn::Tools::Registry.reset_adapters!

        nil
      end
    end
  end
end
