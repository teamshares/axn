# frozen_string_literal: true

RSpec.describe Axn do
  describe "Logging" do
    let(:action) do
      build_axn do
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
      allow(Axn.config).to receive(:logger).and_return(logger)
    end

    it "logs" do
      expect(logger).to receive(:info).with("[Anonymous Class] Hello, World!")
      is_expected.to be_ok
    end

    Axn::Core::Logging::LEVELS.each do |level|
      describe "##{level}" do
        let(:level) { level }

        it "delegates via #log" do
          expect(logger).to receive(level).with("[Anonymous Class] Hello, World!")
          is_expected.to be_ok
        end
      end

      describe "with .log_level set to #{level}" do
        let(:action) do
          build_axn do
            def call
              log("Hello!")
            end
          end.tap do |a|
            a.define_singleton_method(:log_level) { level }
          end
        end

        it "logs at the default level" do
          expect(logger).to receive(level).with("[Anonymous Class] Hello!")
          is_expected.to be_ok
        end
      end
    end
  end
end
