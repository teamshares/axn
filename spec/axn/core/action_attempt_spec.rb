# frozen_string_literal: true

# Unit-tested rather than driven through the executor on purpose. The window between "is it started?"
# and "it is started now" is narrow in the real call path — narrow enough that hundreds of threaded
# executor runs did not hit it — so an integration test here would be probabilistic and would pass
# against a broken implementation most of the time. The invariant belongs to this object, so it is
# tested where it is enforced.
RSpec.describe Axn::Core::ActionAttempt do
  # Every case below is about an action whose result never settled — that is what makes abandonment
  # abandonment. The settled variant gets its own example at the bottom.
  subject(:attempt) { described_class.new(settled: -> { false }) }

  describe "#originating_context?" do
    it "does not accept a Thread that merely claims to be the originating one" do
      # The answer authorizes claiming the notification and running the action, so it must come from
      # the objects rather than from a method either of them defines.
      # The dispatch was on the CURRENT thread, so that is where the lie has to live: it claims to be
      # the recorded thread, which is a different object entirely.
      attempt.instance_variable_set(:@thread, Object.new)
      allow(Thread.current).to receive(:equal?).and_return(true)

      expect(attempt.originating_context?).to be(false)
    end
  end

  describe "#close!" do
    it "refuses both claims afterward" do
      # The attempt does not outlive the tracing boundary. A tracer that captures the block, cancels
      # out before invoking it, and calls it later presents the caller's own thread and fiber — a
      # genuine originating context, just no longer a live one — and the cancellation path leaves both
      # claims un-taken on purpose. Only closure can tell those apart.
      attempt.close!

      expect(attempt.claim).to be(false)
      expect(attempt.claim_notification).to be(false)
    end

    it "does not disturb claims already taken" do
      expect(attempt.claim).to be(true)
      attempt.close!

      expect(attempt.claimed?).to be(true)
      expect(attempt.claim).to be(false)
    end
  end

  describe "#claim" do
    it "grants the first claim" do
      expect(attempt.claim).to be(true)
    end

    it "does not report the action as started merely because the attempt was claimed" do
      # An observer can claim and then fail before reaching the action — a notification subscriber
      # raising from `start`. The untraced fallback has to be able to tell that apart from the action
      # having actually run, so these are two facts, not one.
      attempt.claim

      expect(attempt.started?).to be(false)
    end

    it "refuses every claim after the first" do
      expect(attempt.claim).to be(true)
      expect(attempt.claim).to be(false)
      expect(attempt.claim).to be(false)
    end

    it "lets exactly one of many concurrent threads win" do
      # A tracer may invoke the block it was handed from more than one thread. Checking and claiming
      # have to be one operation, or several threads pass the check before any of them sets the flag.
      20.times do
        fresh = described_class.new(settled: -> { false })
        gate = Queue.new
        threads = 8.times.map do
          Thread.new do
            gate.pop
            fresh.claim
          end
        end
        8.times { gate << :go }

        expect(threads.map(&:value).count(true)).to eq(1)
      end
    end
  end

  describe "#claim_notification" do
    it "grants the first claim and refuses the rest" do
      expect(attempt.claim_notification).to be(true)
      expect(attempt.claim_notification).to be(false)
    end

    it "is independent of the action claim" do
      # A notification can be attempted and fail before the action begins; the two events are tracked
      # separately so that failure does not also consume the action's one attempt.
      expect(attempt.claim_notification).to be(true)
      expect(attempt.claim).to be(true)
    end

    it "lets exactly one of many concurrent threads win" do
      20.times do
        fresh = described_class.new(settled: -> { false })
        gate = Queue.new
        threads = 8.times.map do
          Thread.new do
            gate.pop
            fresh.claim_notification
          end
        end
        8.times { gate << :go }

        expect(threads.map(&:value).count(true)).to eq(1)
      end
    end
  end

  describe "#execute" do
    it "returns the block's value and records neither failure nor abandonment" do
      expect(attempt.execute { :the_value }).to eq(:the_value)
      expect(attempt.error).to be_nil
      expect(attempt.abandoned?).to be(false)
      expect(attempt.started?).to be(true)
    end

    it "records and re-raises an exception rather than absorbing it" do
      boom = RuntimeError.new("boom")

      expect { attempt.execute { raise boom } }.to raise_error(boom)
      expect(attempt.error).to be(boom)
      expect(attempt.abandoned?).to be(false)
    end

    it "records an Interrupt, which axn would never settle, for the same reason" do
      expect { attempt.execute { raise Interrupt } }.to raise_error(Interrupt)
      expect(attempt.error).to be_a(Interrupt)
    end

    it "records abandonment when the block unwinds by throw" do
      expect(catch(:cancel) { attempt.execute { throw :cancel, :thrown } }).to eq(:thrown)
      expect(attempt.abandoned?).to be(true)
      expect(attempt.error).to be_nil
    end

    it "does NOT record abandonment when the result had already settled" do
      # The completion side of the action's own block — `log_after`, the timing ensure — runs after
      # `with_exception_handling` settled the result. A throw from there is a side channel failing on
      # its way out of a finished call, not an action that abandoned execution, and marking it
      # abandoned would let a logger take down a completed action.
      settled = described_class.new(settled: -> { true })

      expect(catch(:cancel) { settled.execute { throw :cancel, :thrown } }).to eq(:thrown)
      expect(settled.abandoned?).to be(false)
      expect(settled.error).to be_nil
    end

    it "treats an unanswerable settled predicate as not settled" do
      # Consulted from an `ensure` while a throw unwinds, so it must never raise in place of the
      # in-flight unwind. Unknown means "not known to have settled" — the conservative reading.
      exploding = described_class.new(settled: -> { raise "predicate is broken" })

      expect(catch(:cancel) { exploding.execute { throw :cancel, :thrown } }).to eq(:thrown)
      expect(exploding.abandoned?).to be(true)
    end
  end
end
