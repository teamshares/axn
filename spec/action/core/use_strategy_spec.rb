# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::Core::UseStrategy do
  let(:test_action) { build_action }
  let(:custom_strategy) do
    Module.new do
      extend ActiveSupport::Concern
      included do
        puts "Custom strategy included!"
      end
    end
  end

  before do
    Action::Strategies.clear!
    Action::Strategies.register(:custom, custom_strategy)
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
      end.to raise_error("Strategy unknown_strategy not found")
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

    context "when strategy has a setup method" do
      let(:setup_strategy) do
        Module.new do
          extend ActiveSupport::Concern

          def self.setup(**config, &block)
            puts "Setup called with config: #{config.inspect}"
            puts "Setup called with block: #{block.call if block_given?}"

            Module.new do
              extend ActiveSupport::Concern
              included do
                puts "Setup strategy included!"
              end
            end
          end
        end
      end

      before do
        Action::Strategies.register(:setup_strategy, setup_strategy)
      end

      it "calls setup method with config and block" do
        expected = <<~OUTPUT
          Setup called with config: {:option1=>"value1", :option2=>"value2"}
          Setup called with block: block result
          Setup strategy included!
        OUTPUT

        expect do
          test_action.use(:setup_strategy, option1: "value1", option2: "value2") { "block result" }
        end.to output(expected).to_stdout
      end

      it "calls setup method with only config" do
        expect do
          test_action.use(:setup_strategy, option1: "value1")
        end.to output("Setup called with config: {:option1=>\"value1\"}\nSetup called with block: \nSetup strategy included!\n").to_stdout
      end

      it "calls setup method with only block" do
        expect do
          test_action.use(:setup_strategy) { "block only" }
        end.to output("Setup called with config: {}\nSetup called with block: block only\nSetup strategy included!\n").to_stdout
      end

      it "calls setup method with no arguments" do
        expect do
          test_action.use(:setup_strategy)
        end.to output("Setup called with config: {}\nSetup called with block: \nSetup strategy included!\n").to_stdout
      end
    end

    context "when strategy doesn't have a setup method" do
      it "raises an error when config is provided" do
        expect do
          test_action.use(:custom, option1: "value1")
        end.to raise_error(ArgumentError, "Strategy custom does not support config")
      end

      it "allows block when no config is provided" do
        expect do
          test_action.use(:custom) { "block" }
        end.to raise_error(ArgumentError, "Strategy custom does not support blocks (define #setup method)")
      end
    end
  end
end
