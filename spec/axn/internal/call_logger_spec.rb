# frozen_string_literal: true

RSpec.describe Axn::Internal::CallLogger do
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
