# frozen_string_literal: true

# PRO-3278 review: `isolation_unsafe?` must answer for the THREAD asking, not for the process. It backs
# `Internal::Tracing.current_span`'s isolation-mismatch guard, and the two conditions it checks
# (`Fiber.scheduler`, per-thread; `isolation_level`, process-wide) are read live rather than cached, so a
# hybrid process — some threads running under a scheduler, others not — doesn't have one scheduler-bearing
# thread's mismatch permanently blind every other, unrelated thread for the rest of the process.
RSpec.describe "Axn::Core::NestingTracking.isolation_unsafe?" do
  after { Axn::Core::NestingTracking._reset_isolation_warning! }

  it "is false with no Fiber scheduler installed, regardless of isolation_level" do
    expect(Fiber.scheduler).to be_nil
    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  end

  it "does not read the sticky once-per-process warning flag: it stays scoped to live conditions" do
    # Simulate the flag a DIFFERENT thread's mismatch would have set — the exact state the review
    # finding described. If `isolation_unsafe?` merely read this ivar (the pre-fix implementation), it
    # would answer true for every thread in the process from here on, including this one, which has no
    # scheduler installed and is not actually affected.
    Axn::Core::NestingTracking.instance_variable_set(:@_isolation_mismatch_warned, true)

    expect(Fiber.scheduler).to be_nil
    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  ensure
    Axn::Core::NestingTracking.remove_instance_variable(:@_isolation_mismatch_warned)
  end

  it "is true only when a scheduler is installed AND isolation_level is :thread" do
    allow(Fiber).to receive(:scheduler).and_return(Object.new)
    allow(ActiveSupport::IsolatedExecutionState).to receive(:isolation_level).and_return(:thread)

    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(true)
  end

  it "is false when a scheduler is installed but isolation_level is already :fiber (correctly configured)" do
    allow(Fiber).to receive(:scheduler).and_return(Object.new)
    allow(ActiveSupport::IsolatedExecutionState).to receive(:isolation_level).and_return(:fiber)

    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  end
end
