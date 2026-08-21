# frozen_string_literal: true

require "timeout"

RSpec.describe Axn::Internal::CallLogger do
  describe "#format_object" do
    # `value(n)` nests to depth `n` with exactly one element at each rung — the shape PRO-3203 measured
    # the exponential blowup with (`{f: [{f: [...]}]}`), so a regression here reproduces the same curve.
    def value(n) = n.zero? ? { leaf: "x" } : { f: [value(n - 1)] }

    it "renders each nesting rung once, rather than re-inspecting an already-formatted child" do
      formatted = described_class.send(:format_object, value(2))

      expect(formatted).to eq('{f: [{f: [{leaf: "x"}]}]}')
    end

    # Before the fix, the Array branch handed its parent a raw Array of already-formatted Strings
    # instead of a String — so the parent's string interpolation ran Array#to_s (== #inspect) over
    # already-rendered children, escaping their quotes/backslashes again on every level up. That
    # doubling made rendering (and the emitted line's length) exponential in nesting depth: depth 29
    # measured ~23s with no `shape:`/`of:` declared at all. Depth 30 here is comfortably past where the
    # unfixed code would blow well past the timeout; the fixed code finishes near-instantly.
    it "stays fast at a nesting depth where the exponential renderer was pathological" do
      deeply_nested = value(30)

      Timeout.timeout(2) do
        described_class.send(:format_object, deeply_nested)
      end
    end
  end

  describe "#would_log?" do
    it "asks the configured logger's own severity predicate" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(false)
    end

    it "assumes yes when the logger doesn't expose a severity predicate" do
      logger = double("bare logger") # -- deliberately non-conforming
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(true)
    end
  end

  describe "#log_at_level" do
    it "skips building the log context entirely when the logger reports the level disabled" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)
      action_class = build_axn do
        expects :name
        def call; end
      end

      expect(described_class).not_to receive(:format_context)
      expect(action_class).not_to receive(:info)

      action_class.call(name: "x")
    end

    it "never lets a raising severity predicate escape — the same best_effort boundary as everything else in here" do
      logger = double("broken logger")
      allow(logger).to receive(:info?).and_raise(StandardError, "logger is misconfigured")
      allow(Axn.config).to receive(:logger).and_return(logger)
      action_class = build_axn do
        expects :name
        def call; end
      end

      expect do
        described_class.log_at_level(
          action_class,
          level: :info,
          message_parts: ["hi"],
          error_context: "test",
        )
      end.not_to raise_error
    end
  end
end
