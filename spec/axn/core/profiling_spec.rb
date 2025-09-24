# frozen_string_literal: true

RSpec.describe Axn::Core::Profiling do
  let(:action_class) do
    build_axn do
      expects :name

      def call
        "Hello, #{name}!"
      end
    end
  end

  before do
    # Reset configuration
    action_class._profiling_enabled = false
    action_class._profiling_condition = nil
    action_class._profiling_sample_rate = 0.1
    action_class._profiling_output_dir = nil
  end

  describe ".profile" do
    it "enables profiling for the action class" do
      action_class.profile

      expect(action_class._profiling_enabled).to be true
      expect(action_class._profiling_condition).to be nil
    end

    it "enables profiling with a condition" do
      condition = -> { debug_mode }
      action_class.profile(if: condition)

      expect(action_class._profiling_enabled).to be true
      expect(action_class._profiling_condition).to eq(condition)
    end

    it "enables profiling with a symbol condition" do
      action_class.profile(if: :should_profile?)

      expect(action_class._profiling_enabled).to be true
      expect(action_class._profiling_condition).to eq(:should_profile?)
    end

    it "enables profiling with custom sample rate and output dir" do
      action_class.profile(sample_rate: 0.5, output_dir: "custom/profiles")

      expect(action_class._profiling_enabled).to be true
      expect(action_class._profiling_sample_rate).to eq(0.5)
      expect(action_class._profiling_output_dir).to eq("custom/profiles")
    end

    it "uses default sample rate and output dir when not provided" do
      action_class.profile

      expect(action_class._profiling_enabled).to be true
      expect(action_class._profiling_sample_rate).to eq(0.1)
      expect(action_class._profiling_output_dir).to be_a(Pathname)
    end
  end

  describe "#_should_profile?" do
    let(:action) { action_class.new(name: "World") }

    context "when profiling is disabled for the action" do
      it "returns false" do
        action_class._profiling_enabled = false
        expect(action.send(:_should_profile?)).to be false
      end
    end

    context "when profiling is enabled without condition" do
      before do
        action_class._profiling_enabled = true
      end

      it "returns true" do
        expect(action.send(:_should_profile?)).to be true
      end
    end

    context "when profiling is enabled with proc condition" do
      let(:action_class) do
        build_axn do
          expects :name, :debug_mode

          def call
            "Hello, #{name}!"
          end
        end
      end

      before do
        action_class._profiling_enabled = true
      end

      it "returns true when condition evaluates to true" do
        action_class._profiling_condition = -> { debug_mode }
        action = action_class.new(name: "World", debug_mode: true)

        expect(action.send(:_should_profile?)).to be true
      end

      it "returns false when condition evaluates to false" do
        action_class._profiling_condition = -> { debug_mode }
        action = action_class.new(name: "World", debug_mode: false)

        expect(action.send(:_should_profile?)).to be false
      end
    end

    context "when profiling is enabled with symbol condition" do
      before do
        action_class._profiling_enabled = true
      end

      it "calls the method and returns its result" do
        action_class._profiling_condition = :should_profile?

        expect(action).to receive(:should_profile?).and_return(true)
        expect(action.send(:_should_profile?)).to be true
      end
    end

    context "when profiling is enabled with callable condition" do
      before do
        action_class._profiling_enabled = true
      end

      it "calls the callable and returns its result" do
        callable = -> { name == "World" }
        action_class._profiling_condition = callable

        expect(action.send(:_should_profile?)).to be true
      end
    end
  end

  describe "#_ensure_vernier_available!" do
    let(:action) { action_class.new(name: "World") }

    context "when Vernier is available" do
      before do
        stub_const("Vernier", Module.new)
      end

      it "does not raise an error" do
        expect { action.send(:_ensure_vernier_available!) }.not_to raise_error
      end
    end
  end

  describe "#_with_profiling" do
    let(:action) { action_class.new(name: "World") }

    context "when profiling should not run" do
      before do
        allow(action).to receive(:_should_profile?).and_return(false)
      end

      it "yields without profiling" do
        expect(action).not_to receive(:_ensure_vernier_available!)

        result = action.send(:_with_profiling) { "test" }
        expect(result).to eq("test")
      end
    end

    context "when profiling should run" do
      before do
        action_class.profile # Enable profiling on the action class
        allow(action).to receive(:_should_profile?).and_return(true)
        stub_const("Vernier", Module.new)
        allow(Vernier).to receive(:profile).and_yield
      end

      it "ensures Vernier is available" do
        expect(action).to receive(:_ensure_vernier_available!)

        action.send(:_with_profiling) { "test" }
      end

      it "calls Vernier.profile with a profile name and options" do
        expect(Vernier).to receive(:profile).with(
          hash_including(
            out: match(/axn_AnonymousAction_\d+\.json$/),
            allocation_sample_rate: 100,
          ),
        ).and_yield

        action.send(:_with_profiling) { "test" }
      end

      it "yields the block to Vernier.profile" do
        yielded_value = nil
        allow(Vernier).to receive(:profile) do |&block|
          yielded_value = block.call
        end

        result = action.send(:_with_profiling) { "test" }
        expect(yielded_value).to eq("test")
        expect(result).to eq("test")
      end
    end
  end

  describe "integration with action execution" do
    let(:action) { action_class.new(name: "World") }

    before do
      action_class.profile
      stub_const("Vernier", Module.new)
      allow(Vernier).to receive(:profile).and_yield
    end

    it "profiles the complete action execution" do
      expect(Vernier).to receive(:profile).with(
        hash_including(
          out: match(/axn_AnonymousAction_\d+\.json$/),
          allocation_sample_rate: 100,
        ),
      ).and_yield

      action_class.call(name: "World")
    end

    it "includes the action class name in the profile name" do
      expect(Vernier).to receive(:profile).with(
        hash_including(
          out: match(/axn_AnonymousAction_\d+\.json$/),
          allocation_sample_rate: 100,
        ),
      ).and_yield

      action_class.call(name: "World")
    end
  end

  describe "default values" do
    it "has default profiling values" do
      expect(action_class._profiling_sample_rate).to eq(0.1)
      expect(action_class._profiling_output_dir).to be_nil
    end

    it "allows setting custom profiling values" do
      action_class.profile(sample_rate: 0.5, output_dir: "custom/profiles")

      expect(action_class._profiling_sample_rate).to eq(0.5)
      expect(action_class._profiling_output_dir).to eq("custom/profiles")
    end
  end
end
