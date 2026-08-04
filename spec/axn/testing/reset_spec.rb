# frozen_string_literal: true

require "axn/testing"

RSpec.describe Axn::Testing do
  describe ".reset!" do
    # Sidekiq isn't in the root bundle, so `register!` can't run for real here (it no-ops without
    # `defined?(::Sidekiq)`). Setting the flags directly simulates a process where registration
    # already happened — which is the only state `reset!` needs to tell apart from "never
    # registered". Restored in `ensure` because these ivars are real process-global state this
    # example doesn't own.
    it "leaves the Sidekiq auto-configure registration flags alone, but drops the validation memo" do
      autoconfig = Axn::Async::Adapters::Sidekiq::AutoConfigure
      before_registered = autoconfig.registered?
      before_middleware = autoconfig.middleware_registered?
      before_death_handler = autoconfig.death_handler_registered?

      autoconfig.instance_variable_set(:@registered, true)
      autoconfig.instance_variable_set(:@middleware_registered, true)
      autoconfig.instance_variable_set(:@death_handler_registered, true)
      autoconfig.instance_variable_set(:@validated, true)

      described_class.reset!

      expect(autoconfig.registered?).to be(true)
      expect(autoconfig.middleware_registered?).to be(true)
      expect(autoconfig.death_handler_registered?).to be(true)
      expect(autoconfig.validated?).to be(false)
    ensure
      autoconfig.instance_variable_set(:@registered, before_registered)
      autoconfig.instance_variable_set(:@middleware_registered, before_middleware)
      autoconfig.instance_variable_set(:@death_handler_registered, before_death_handler)
    end

    it "drops the tracer auto-detection memos" do
      Axn::Internal::Tracing.autodetected_tracer
      described_class.reset!
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@tracer_entry)).to be(false)
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@probe_entry)).to be(false)
    end

    it "re-arms the one-time fiber-isolation warning" do
      Axn::Core::NestingTracking.instance_variable_set(:@_isolation_mismatch_warned, true)
      described_class.reset!
      expect(Axn::Core::NestingTracking.instance_variable_defined?(:@_isolation_mismatch_warned)).to be(false)
    end

    it "is idempotent, so a before hook can call it unconditionally" do
      expect { 2.times { described_class.reset! } }.not_to raise_error
    end

    # The load-bearing exclusions. A host app configures axn in an initializer; a suite-wide
    # `before { Axn::Testing.reset! }` that reset config would silently un-configure every example
    # after the first, presenting as unrelated failures deep in someone else's suite.
    #
    # Read-compare-read, not a mutate-then-assert or a spy on one named setter: this never writes to
    # the real singleton (so there's nothing to leak or restore), and it catches every mechanism that
    # would count as "reset config" — replacing `@config` wholesale, a bag-reset, or a setter this
    # example didn't happen to name — not just the one setter a spy would watch.
    it "leaves Axn.config alone" do
      config_object_id = Axn.config.object_id
      log_level_before = Axn.config.log_level

      described_class.reset!

      expect(Axn.config.object_id).to eq(config_object_id)
      expect(Axn.config.log_level).to eq(log_level_before)
    end

    it "leaves registered strategies alone" do
      before_keys = Axn::Strategies.all.keys
      described_class.reset!
      expect(Axn::Strategies.all.keys).to eq(before_keys)
    end

    # `Tools::Registry`'s recorded action classes accumulate every action class defined in the
    # process; clearing them mid-suite would make `Axn.tools_for` blind to classes still loaded.
    # Named (via stub_const) rather than anonymous: an anonymous class is filtered out of
    # `all_classes` as stale on every enumeration regardless of `reset!`, so it can't demonstrate
    # this exclusion either way.
    it "leaves Tools::Registry's recorded action classes alone" do
      stub_const("ResetSpecProbeAction", build_axn { def call = nil })
      before_classes = Axn::Tools::Registry.all_classes

      described_class.reset!

      expect(Axn::Tools::Registry.all_classes).to eq(before_classes)
    end

    # An adapter gem registers at file-load time, and `require` runs once per process — a
    # registration dropped here could never be re-established, unlike the rest of this describe
    # block's derived state, which the process can always regenerate. Registering the probe adapter
    # is what this exclusion needs to demonstrate (nothing else in the suite exercises registration
    # to give us a fixture), and it costs nothing to leave in place: axn's own spec_helper resets
    # adapters before every example, so the probe is gone before the next example runs.
    it "leaves Tools::Registry's registered adapters alone" do
      Axn::Tools.register_adapter(:reset_probe)
      before_adapters = Axn::Tools::Registry.adapters

      described_class.reset!

      expect(Axn::Tools::Registry.adapters).to eq(before_adapters)
    end
  end
end
