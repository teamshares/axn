# frozen_string_literal: true

# axn keeps all per-execution shared state in ActiveSupport::IsolatedExecutionState, which is scoped
# by `isolation_level`. Under the default :thread, concurrent fibers on one thread share that state —
# so a fiber-based host (async/Falcon) that hasn't set `:fiber` would silently corrupt axn's nesting
# stack and exception-classification sets. We can't fix that for the host (flipping the global at
# runtime calls IsolatedExecutionState.clear and would nuke AR/CurrentAttributes), but we CAN detect
# the dangerous combination — a fiber scheduler is installed AND isolation_level is :thread — and warn.
RSpec.describe "Fiber isolation mismatch warning" do
  let(:logger) { instance_double(Logger, warn: nil, debug: nil, info: nil, error: nil) }

  before do
    allow(Axn.config).to receive(:logger).and_return(logger)
    # warn-once is process-global; reset so each example starts fresh
    Axn::Core::NestingTracking.instance_variable_set(:@_isolation_mismatch_warned, false)
    stub_const("NoopAxn", build_axn { def call = nil })
  end

  def run_noop_axn = NoopAxn.call

  context "when a fiber scheduler is active under :thread isolation" do
    before { allow(Fiber).to receive(:scheduler).and_return(Object.new) }

    it "warns about the isolation_level mismatch" do
      run_noop_axn
      expect(logger).to have_received(:warn).with(/isolation_level/i).once
    end

    it "warns only once across multiple call trees" do
      run_noop_axn
      run_noop_axn
      run_noop_axn
      expect(logger).to have_received(:warn).with(/isolation_level/i).once
    end
  end

  context "when no fiber scheduler is present (plain threads / Sidekiq)" do
    before { allow(Fiber).to receive(:scheduler).and_return(nil) }

    it "does not warn" do
      run_noop_axn
      expect(logger).not_to have_received(:warn)
    end
  end

  context "when isolation_level is already :fiber" do
    around do |example|
      previous = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      example.run
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = previous
    end

    before { allow(Fiber).to receive(:scheduler).and_return(Object.new) }

    it "does not warn (host has correctly opted into fiber isolation)" do
      run_noop_axn
      expect(logger).not_to have_received(:warn)
    end
  end
end
