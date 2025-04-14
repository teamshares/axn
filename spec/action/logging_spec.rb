# frozen_string_literal: true

RSpec.describe Action do
  describe "Logging" do
    let(:action) do
      build_action do
        expects :level, default: :info
        def call
          log("Hello, World!", level:)
        end
      end
    end
    let(:level) { :info }
    let(:logger) { instance_double(Logger, debug: nil, info: nil, error: nil, warn: nil, fatal: nil) }

    subject { action.call(level:) }

    before do
      allow(Action.config).to receive(:logger).and_return(logger)
    end

    it "logs" do
      expect(logger).to receive(:info).with("[Anonymous Class] Hello, World!")
      is_expected.to be_ok
    end

    Action::Logging::LEVELS.each do |level|
      describe "##{level}" do
        let(:level) { level }

        it "delegates via #log" do
          expect(logger).to receive(level).with("[Anonymous Class] Hello, World!")
          is_expected.to be_ok
        end
      end
    end

    describe "with ._targeted_for_debug_logging?" do
      let(:level) { :debug }

      before do
        allow(action).to receive(:_targeted_for_debug_logging?).and_return(targeted_for_debug_logging)
      end

      context "false" do
        let(:targeted_for_debug_logging) { false }
        it "logs debug at debug level" do
          expect(logger).to receive(:debug).with("[Anonymous Class] Hello, World!")
          is_expected.to be_ok
        end
      end

      context "true" do
        let(:targeted_for_debug_logging) { true }
        it "logs debug at info level" do
          expect(logger).to receive(:info).with("[Anonymous Class] Hello, World!")
          is_expected.to be_ok
        end
      end
    end
  end
end
