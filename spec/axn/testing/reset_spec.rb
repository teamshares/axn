# frozen_string_literal: true

require "axn/testing"

RSpec.describe Axn::Testing do
  describe ".reset!" do
    it "drops the tracer auto-detection memos" do
      Axn::Internal::Tracing.autodetected_tracer
      described_class.reset!
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@tracer_entry)).to be(false)
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@probe_entry)).to be(false)
    end

    it "drops registered tool-adapter sources" do
      Axn::Tools.register_adapter(:reset_probe)
      expect(Axn::Tools::Registry.adapters).to include(:reset_probe)

      described_class.reset!
      expect(Axn::Tools::Registry.adapters).to be_empty
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
    it "leaves Axn.config alone" do
      expect(Axn.config).not_to receive(:log_level=)
      described_class.reset!
    end

    it "leaves registered strategies alone" do
      before_keys = Axn::Strategies.all.keys
      described_class.reset!
      expect(Axn::Strategies.all.keys).to eq(before_keys)
    end
  end
end
