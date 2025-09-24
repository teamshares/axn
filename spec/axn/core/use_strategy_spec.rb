# frozen_string_literal: true

RSpec.describe Axn::Core::UseStrategy do
  let(:test_action) { build_axn }
  let(:custom_strategy) do
    Module.new do
      extend ActiveSupport::Concern
      included do
        puts "Custom strategy included!"
      end
    end
  end

  before do
    Axn::Strategies.clear!
    Axn::Strategies.register(:custom, custom_strategy)
  end

  describe ".use" do
    it "includes the strategy by name" do
      expect do
        test_action.use(:custom)
      end.to output("Custom strategy included!\n").to_stdout

      expect(test_action.included_modules).to include(custom_strategy)
    end

    it "raises an error for unknown strategy names" do
      expect do
        test_action.use(:unknown_strategy)
      end.to raise_error(Axn::StrategyNotFound, "Strategy 'unknown_strategy' not found")
    end

    it "finds strategies by symbol name" do
      expect do
        test_action.use(:custom)
      end.to output("Custom strategy included!\n").to_stdout
    end

    it "finds strategies by string name" do
      expect do
        test_action.use("custom")
      end.to output("Custom strategy included!\n").to_stdout
    end

    context "when strategy has a configure method" do
      let(:setup_strategy) do
        Module.new do
          extend ActiveSupport::Concern

          def self.configure(**config, &block)
            puts "Configure called with config: #{config.inspect}"
            puts "Configure called with block: #{block.call if block_given?}"

            Module.new do
              extend ActiveSupport::Concern
              included do
                puts "Configure strategy included!"
              end
            end
          end
        end
      end

      before do
        Axn::Strategies.register(:setup_strategy, setup_strategy)
      end

      it "calls configure method with config and block" do
        expected = <<~OUTPUT
          Configure called with config: {:option1=>"value1", :option2=>"value2"}
          Configure called with block: block result
          Configure strategy included!
        OUTPUT

        expect do
          test_action.use(:setup_strategy, option1: "value1", option2: "value2") { "block result" }
        end.to output(expected).to_stdout
      end

      it "calls configure method with only config" do
        expect do
          test_action.use(:setup_strategy, option1: "value1")
        end.to output("Configure called with config: {:option1=>\"value1\"}\nConfigure called with block: \nConfigure strategy included!\n").to_stdout
      end

      it "calls configure method with only block" do
        expect do
          test_action.use(:setup_strategy) { "block only" }
        end.to output("Configure called with config: {}\nConfigure called with block: block only\nConfigure strategy included!\n").to_stdout
      end

      it "calls configure method with no arguments" do
        expect do
          test_action.use(:setup_strategy)
        end.to output("Configure called with config: {}\nConfigure called with block: \nConfigure strategy included!\n").to_stdout
      end
    end

    context "when strategy doesn't have a configure method" do
      it "raises an error when config is provided" do
        expect do
          test_action.use(:custom, option1: "value1")
        end.to raise_error(ArgumentError, "Strategy custom does not support config")
      end

      it "allows block when no config is provided" do
        expect do
          test_action.use(:custom) { "block" }
        end.to raise_error(ArgumentError, "Strategy custom does not support blocks (define #configure method)")
      end
    end
  end
end
