# frozen_string_literal: true

RSpec.describe Axn::Internal::PipingError do
  describe ".swallow" do
    let(:exception) { StandardError.new("fail message") }
    let(:backtrace) { ["/foo/bar/baz.rb:42:in `block in call'"] }
    let(:logger) { double(:logger) }

    before do
      exception.set_backtrace(backtrace)
      allow(Axn).to receive_message_chain(:config, :logger).and_return(logger)
      allow(Axn).to receive_message_chain(:config, :raise_piping_errors_in_dev).and_return(false)
      allow(logger).to receive(:warn)
    end

    context "in production" do
      before do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
      end

      it "logs a concise warning" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
        described_class.swallow("foo", exception:)
      end

      it "returns nil" do
        expect(described_class.swallow("foo", exception:)).to be_nil
      end
    end

    context "in non-production" do
      before do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
      end

      it "logs a verbose warning" do
        expected_message = [
          "⌵" * 30,
          "",
          "!! IGNORING EXCEPTION RAISED WHILE FOO !!",
          "",
          "\t* Exception: StandardError",
          "\t* Message: fail message",
          "\t* From: baz.rb:42",
          "",
          "^" * 30,
        ].join("\n")
        expect(logger).to receive(:warn).with(expected_message)
        described_class.swallow("foo", exception:)
      end

      it "returns nil" do
        expect(described_class.swallow("foo", exception:)).to be_nil
      end
    end

    context "with custom action logger" do
      let(:custom_action) { double(:action_logger) }
      it "uses the action's logger if provided" do
        expect(custom_action).to receive(:warn).with(/Ignoring exception raised while foo/)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        described_class.swallow("foo", exception:, action: custom_action)
      end
    end

    context "with raise_piping_errors_in_dev enabled" do
      before do
        allow(Axn).to receive_message_chain(:config, :raise_piping_errors_in_dev).and_return(true)
      end

      context "in development" do
        before do
          allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        end

        it "raises the exception instead of logging" do
          expect(logger).not_to receive(:warn)
          expect { described_class.swallow("foo", exception:) }.to raise_error(StandardError, "fail message")
        end
      end

      context "in test" do
        before do
          allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(false)
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        end

        it "logs and does not raise (matches production behavior)" do
          expect(logger).to receive(:warn)
          expect { described_class.swallow("foo", exception:) }.not_to raise_error
        end
      end

      context "in production" do
        before do
          allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(false)
          allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        end

        it "logs and does not raise" do
          expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
          expect { described_class.swallow("foo", exception:) }.not_to raise_error
        end
      end
    end

    context "with raise_piping_errors_in_dev disabled" do
      before do
        allow(Axn).to receive_message_chain(:config, :raise_piping_errors_in_dev).and_return(false)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
      end

      it "logs and does not raise" do
        expect(logger).to receive(:warn)
        expect { described_class.swallow("foo", exception:) }.not_to raise_error
      end
    end
  end
end
