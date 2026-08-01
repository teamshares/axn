# frozen_string_literal: true

# Unit-tested rather than driven through the executor on purpose. The window between "is it started?"
# and "it is started now" is narrow in the real call path — narrow enough that hundreds of threaded
# executor runs did not hit it — so an integration test here would be probabilistic and would pass
# against a broken implementation most of the time. The invariant belongs to this object, so it is
# tested where it is enforced.
RSpec.describe Axn::Core::ActionAttempt do
  subject(:attempt) { described_class.new }

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
        fresh = described_class.new
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
        fresh = described_class.new
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
  end
end
