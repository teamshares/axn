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

    describe "_log_prefix with nested actions" do
      let(:logger) { instance_double(Logger, info: nil) }

      before { allow(Axn.config).to receive(:logger).and_return(logger) }

      context "when action is called at top level" do
        let(:action) do
          build_axn do
            def call
              log("test message")
            end
          end
        end

        it "uses single bracketed prefix" do
          expect(logger).to receive(:info).with("[Anonymous Class] test message")
          action.call
        end
      end

      context "when action is nested one level deep" do
        let(:outer_action) do
          inner = inner_action
          build_axn do
            define_method(:call) { inner.call }
          end
        end

        let(:inner_action) do
          build_axn do
            def call
              log("inner message")
            end
          end
        end

        it "includes outer action name in prefix with chevron separator" do
          expect(logger).to receive(:info).with(/\[Anonymous Class > Anonymous Class\] inner message/)
          outer_action.call
        end
      end

      context "when action is nested multiple levels deep" do
        let(:level1) do
          l2 = level2
          build_axn do
            define_method(:call) { l2.call }
          end
        end

        let(:level2) do
          l3 = level3
          build_axn do
            define_method(:call) { l3.call }
          end
        end

        let(:level3) do
          build_axn do
            def call
              log("deep message")
            end
          end
        end

        it "stacks all parent action names with chevron separators" do
          expect(logger).to receive(:info).with(/\[Anonymous Class > Anonymous Class > Anonymous Class\] deep message/)
          level1.call
        end
      end

      context "with named action classes" do
        before do
          stub_const("OuterAction", build_axn)
          stub_const("InnerAction", build_axn do
            def call
              log("from inner")
            end
          end)

          OuterAction.class_eval do
            define_method(:call) { InnerAction.call }
          end
        end

        it "uses actual class names in prefix" do
          expect(logger).to receive(:info).with("[OuterAction > InnerAction] from inner")
          OuterAction.call
        end
      end
    end
  end
end
