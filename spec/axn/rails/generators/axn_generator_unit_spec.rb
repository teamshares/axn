# frozen_string_literal: true

require "rails/generators"
require "axn/rails/generators/axn_generator"

RSpec.describe Axn::RailsIntegration::Generators::AxnGenerator do
  describe "class methods" do
    describe ".source_root" do
      it "returns the correct source root" do
        expect(described_class.source_root).to eq(
          File.expand_path("templates", File.join(File.dirname(__FILE__), "../../../../lib/axn/rails/generators")),
        )
      end
    end
  end

  describe "instance methods" do
    let(:generator) { described_class.new(["Test::Action", "param1", "param2"]) }

    describe "#class_name" do
      it "returns the correct class name" do
        expect(generator.send(:class_name)).to eq("Test::Action")
      end
    end

    describe "#file_path" do
      it "returns the correct file path" do
        expect(generator.send(:file_path)).to eq("test/action")
      end
    end

    describe "#expectations" do
      it "returns the expectations array" do
        expect(generator.expectations).to eq(%w[param1 param2])
      end
    end

    describe "#expectations_with_types" do
      it "returns expectations with default types" do
        expect(generator.send(:expectations_with_types)).to eq([
                                                                 { name: "param1", type: "String" },
                                                                 { name: "param2", type: "String" },
                                                               ])
      end
    end

    describe "#rspec_available?" do
      it "returns true when RSpec is defined" do
        expect(generator.send(:rspec_available?)).to be_truthy
      end
    end

    describe "#spec_generation_skipped?" do
      context "when Rails application is not available" do
        before do
          allow(Rails).to receive(:application).and_return(nil)
        end

        it "returns false" do
          expect(generator.send(:spec_generation_skipped?)).to be_falsey
        end
      end

      context "when Rails application is available" do
        let(:mock_config) { double("config") }
        let(:mock_generators_config) { double("generators_config") }

        before do
          allow(Rails).to receive(:application).and_return(double("application", config: mock_config))
          allow(mock_config).to receive(:generators).and_return(mock_generators_config)
        end

        context "when test_framework is disabled" do
          before do
            allow(mock_generators_config).to receive(:respond_to?).with(:test_framework).and_return(true)
            allow(mock_generators_config).to receive(:test_framework).and_return(false)
          end

          it "returns true" do
            expect(generator.send(:spec_generation_skipped?)).to be_truthy
          end
        end

        context "when specs is disabled" do
          before do
            allow(mock_generators_config).to receive(:respond_to?).with(:test_framework).and_return(false)
            allow(mock_generators_config).to receive(:respond_to?).with("specs").and_return(true)
            allow(mock_generators_config).to receive(:respond_to?).with("axn_specs").and_return(false)
            allow(mock_generators_config).to receive(:specs).and_return(false)
          end

          it "returns true" do
            expect(generator.send(:spec_generation_skipped?)).to be_truthy
          end
        end

        context "when axn_specs is disabled" do
          before do
            allow(mock_generators_config).to receive(:respond_to?).with(:test_framework).and_return(false)
            allow(mock_generators_config).to receive(:respond_to?).with("specs").and_return(false)
            allow(mock_generators_config).to receive(:respond_to?).with("axn_specs").and_return(true)
            allow(mock_generators_config).to receive(:axn_specs).and_return(false)
          end

          it "returns true" do
            expect(generator.send(:spec_generation_skipped?)).to be_truthy
          end
        end

        context "when both specs and axn_specs are enabled" do
          before do
            allow(mock_generators_config).to receive(:respond_to?).with(:test_framework).and_return(false)
            allow(mock_generators_config).to receive(:respond_to?).with("specs").and_return(true)
            allow(mock_generators_config).to receive(:respond_to?).with("axn_specs").and_return(true)
            allow(mock_generators_config).to receive(:specs).and_return(true)
            allow(mock_generators_config).to receive(:axn_specs).and_return(true)
          end

          it "returns false" do
            expect(generator.send(:spec_generation_skipped?)).to be_falsey
          end
        end
      end
    end

    describe "#spec_generation_enabled?" do
      context "when RSpec is not available" do
        before do
          allow(generator).to receive(:rspec_available?).and_return(false)
        end

        it "returns false" do
          expect(generator.send(:spec_generation_enabled?)).to be_falsey
        end
      end

      context "when RSpec is available but spec generation is skipped" do
        before do
          allow(generator).to receive(:rspec_available?).and_return(true)
          allow(generator).to receive(:spec_generation_skipped?).and_return(true)
        end

        it "returns false" do
          expect(generator.send(:spec_generation_enabled?)).to be_falsey
        end
      end

      context "when RSpec is available and spec generation is not skipped" do
        before do
          allow(generator).to receive(:rspec_available?).and_return(true)
          allow(generator).to receive(:spec_generation_skipped?).and_return(false)
        end

        it "returns true" do
          expect(generator.send(:spec_generation_enabled?)).to be_truthy
        end
      end
    end
  end

  describe "with different class names" do
    it "handles simple class names" do
      generator = described_class.new(["SimpleClass"])
      expect(generator.send(:class_name)).to eq("SimpleClass")
      expect(generator.send(:file_path)).to eq("simple_class")
    end

    it "handles namespaced class names" do
      generator = described_class.new(["Namespace::Class::Name"])
      expect(generator.send(:class_name)).to eq("Namespace::Class::Name")
      expect(generator.send(:file_path)).to eq("namespace/class/name")
    end

    it "handles single level namespacing" do
      generator = described_class.new(["Module::Class"])
      expect(generator.send(:class_name)).to eq("Module::Class")
      expect(generator.send(:file_path)).to eq("module/class")
    end
  end

  describe "with different expectation counts" do
    it "handles no expectations" do
      generator = described_class.new(["NoExpectations"])
      expect(generator.expectations).to eq([])
    end

    it "handles single expectation" do
      generator = described_class.new(%w[SingleExpectation param])
      expect(generator.expectations).to eq(["param"])
    end

    it "handles multiple expectations" do
      generator = described_class.new(%w[MultiExpectation param1 param2 param3])
      expect(generator.expectations).to eq(%w[param1 param2 param3])
    end
  end
end
