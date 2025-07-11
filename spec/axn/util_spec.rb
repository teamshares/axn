# frozen_string_literal: true

RSpec.describe Axn::Util do
  describe ".piping_error" do
    let(:exception) { StandardError.new("fail message") }
    let(:backtrace) { ["/foo/bar/baz.rb:42:in `block in call'"] }
    let(:logger) { double(:logger) }

    before do
      exception.set_backtrace(backtrace)
      allow(Action).to receive_message_chain(:config, :logger).and_return(logger)
      allow(logger).to receive(:warn)
    end

    context "in production" do
      before do
        allow(Action).to receive_message_chain(:config, :env, :production?).and_return(true)
      end

      it "logs a concise warning" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
        described_class.piping_error("foo", exception:)
      end

      it "returns nil" do
        expect(described_class.piping_error("foo", exception:)).to be_nil
      end
    end

    context "in non-production" do
      before do
        allow(Action).to receive_message_chain(:config, :env, :production?).and_return(false)
      end

      it "logs a verbose warning" do
        expected_message = [
          "******************************",
          "",
          "!! IGNORING EXCEPTION RAISED WHILE FOO !!",
          "",
          "\t* Exception: StandardError",
          "\t* Message: fail message",
          "\t* From: baz.rb:42",
          "",
          "******************************",
        ].join("\n")
        expect(logger).to receive(:warn).with(expected_message)
        described_class.piping_error("foo", exception:)
      end

      it "returns nil" do
        expect(described_class.piping_error("foo", exception:)).to be_nil
      end
    end

    context "with custom action logger" do
      let(:custom_action) { double(:action_logger) }
      it "uses the action's logger if provided" do
        expect(custom_action).to receive(:warn).with(/Ignoring exception raised while foo/)
        allow(Action).to receive_message_chain(:config, :env, :production?).and_return(true)
        described_class.piping_error("foo", exception:, action: custom_action)
      end
    end
  end
end
