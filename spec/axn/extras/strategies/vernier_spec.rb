# frozen_string_literal: true

RSpec.describe Axn::Extras::Strategies::Vernier do
  before do
    Axn::Strategies.clear!
    Axn::Strategies.register(:vernier, described_class)
  end

  let(:action_class) do
    build_axn do
      use :vernier

      expects :name

      def call
        "Hello, #{name}!"
      end
    end
  end

  describe ".configure" do
    it "returns a module" do
      strategy = Axn::Extras::Strategies::Vernier.configure
      expect(strategy).to be_a(Module)
    end

    it "accepts if condition" do
      condition = -> { debug_mode }
      strategy = Axn::Extras::Strategies::Vernier.configure(if: condition)

      action_class = build_axn do
        include strategy

        expects :name, :debug_mode

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_condition).to eq(condition)
    end

    it "accepts sample_rate" do
      strategy = Axn::Extras::Strategies::Vernier.configure(sample_rate: 0.5)

      action_class = build_axn do
        include strategy

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_sample_rate).to eq(0.5)
    end

    it "accepts output_dir" do
      strategy = Axn::Extras::Strategies::Vernier.configure(output_dir: "custom/profiles")

      action_class = build_axn do
        include strategy

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_output_dir).to eq("custom/profiles")
    end

    it "uses default sample_rate when not provided" do
      strategy = Axn::Extras::Strategies::Vernier.configure

      action_class = build_axn do
        include strategy

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_sample_rate).to eq(0.1)
    end

    it "uses default output_dir when not provided" do
      strategy = Axn::Extras::Strategies::Vernier.configure

      action_class = build_axn do
        include strategy

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_output_dir).to be_a(Pathname)
    end
  end

  describe "#_should_profile?" do
    let(:action) { action_class.send(:new, name: "World") }

    context "when no condition is set" do
      it "returns true" do
        expect(action.send(:_should_profile?)).to be true
      end
    end

    context "when condition is a proc" do
      let(:action_class) do
        build_axn do
          use :vernier, if: -> { debug_mode }

          expects :name, :debug_mode

          def call
            "Hello, #{name}!"
          end
        end
      end

      it "returns true when condition evaluates to true" do
        action = action_class.send(:new, name: "World", debug_mode: true)

        expect(action.send(:_should_profile?)).to be true
      end

      it "returns false when condition evaluates to false" do
        action = action_class.send(:new, name: "World", debug_mode: false)

        expect(action.send(:_should_profile?)).to be false
      end
    end

    context "when condition is a symbol" do
      let(:action_class) do
        build_axn do
          use :vernier, if: :should_profile?

          expects :name

          def call
            "Hello, #{name}!"
          end

          private

          def should_profile?
            name == "World"
          end
        end
      end

      it "calls the method and returns its result" do
        action = action_class.send(:new, name: "World")
        expect(action.send(:_should_profile?)).to be true

        action = action_class.send(:new, name: "Other")
        expect(action.send(:_should_profile?)).to be false
      end
    end
  end

  describe "#_ensure_vernier_available!" do
    let(:action) { action_class.send(:new, name: "World") }

    context "when Vernier is available" do
      before do
        stub_const("Vernier", Module.new)
      end

      it "does not raise an error" do
        expect { action.send(:_ensure_vernier_available!) }.not_to raise_error
      end
    end
  end

  describe "#_with_vernier_profiling" do
    let(:action) { action_class.send(:new, name: "World") }

    context "when profiling should not run" do
      let(:action_class) do
        build_axn do
          use :vernier, if: -> { false }

          expects :name

          def call
            "Hello, #{name}!"
          end
        end
      end

      it "yields without profiling" do
        expect(action).not_to receive(:_ensure_vernier_available!)

        result = action.send(:_with_vernier_profiling) { "test" }
        expect(result).to eq("test")
      end
    end

    context "when profiling should run" do
      before do
        stub_const("Vernier", Module.new)
        allow(Vernier).to receive(:profile).and_yield
      end

      it "ensures Vernier is available" do
        expect(action).to receive(:_ensure_vernier_available!)

        action.send(:_with_vernier_profiling) { "test" }
      end

      it "calls Vernier.profile with a profile name and options" do
        expect(Vernier).to receive(:profile).with(
          hash_including(
            out: match(/axn_AnonymousAction_\d+\.json$/),
            allocation_sample_rate: 100,
          ),
        ).and_yield

        action.send(:_with_vernier_profiling) { "test" }
      end

      it "yields the block to Vernier.profile" do
        yielded_value = nil
        allow(Vernier).to receive(:profile) do |&block|
          yielded_value = block.call
        end

        result = action.send(:_with_vernier_profiling) { "test" }
        expect(yielded_value).to eq("test")
        expect(result).to eq("test")
      end
    end
  end

  describe "integration with action execution" do
    before do
      stub_const("Vernier", Module.new)
      allow(Vernier).to receive(:profile).and_yield
    end

    it "profiles the complete action execution via around hook" do
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

    context "with conditional profiling" do
      let(:action_class) do
        build_axn do
          use :vernier, if: -> { debug_mode }

          expects :name, :debug_mode

          def call
            "Hello, #{name}!"
          end
        end
      end

      it "profiles when condition is true" do
        expect(Vernier).to receive(:profile).and_yield

        action_class.call(name: "World", debug_mode: true)
      end

      it "does not profile when condition is false" do
        expect(Vernier).not_to receive(:profile)

        action_class.call(name: "World", debug_mode: false)
      end
    end

    context "with custom sample rate" do
      let(:action_class) do
        build_axn do
          use :vernier, sample_rate: 0.5

          expects :name

          def call
            "Hello, #{name}!"
          end
        end
      end

      it "uses the custom sample rate" do
        expect(Vernier).to receive(:profile).with(
          hash_including(
            allocation_sample_rate: 500,
          ),
        ).and_yield

        action_class.call(name: "World")
      end
    end
  end

  describe "via use strategy" do
    it "can be used via use :vernier" do
      action_class = build_axn do
        use :vernier

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class.included_modules).to include(
        be_a(Module).and(satisfy { |m| m.name.nil? }),
      )
    end

    it "can be configured via use :vernier with options" do
      action_class = build_axn do
        use :vernier, sample_rate: 0.5, output_dir: "custom/profiles"

        expects :name

        def call
          "Hello, #{name}!"
        end
      end

      expect(action_class._vernier_sample_rate).to eq(0.5)
      expect(action_class._vernier_output_dir).to eq("custom/profiles")
    end
  end
end
