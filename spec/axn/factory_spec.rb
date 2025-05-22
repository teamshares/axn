# frozen_string_literal: true

RSpec.shared_examples "can build Axns from callables" do
  subject(:axn) { builder.call }

  context "basic building" do
    let(:callable) do
      ->(arg:, expected:) { log "got expected=#{expected}, arg=#{arg}" }
    end

    it "builds an Axn from a callable" do
      expect(Axn::Factory).to receive(:build).and_call_original
      expect(callable).to be_a(Proc)
      expect(axn < Action).to eq(true)
      expect(axn.call(expected: true, arg: 123)).to be_ok
      expect(axn.call).not_to be_ok
    end
  end

  context "setting expose_return_as" do
    let(:kwargs) { { expose_return_as: :value } }

    let(:callable) do
      -> { 123 }
    end

    it "works correctly" do
      expect(axn.call).to be_ok
      expect(axn.call.value).to eq(123)
    end
  end

  context "setting messages, expects, exposes" do
    let(:kwargs) do
      {
        messages: { error: "error", success: "success" },
        exposes: [:num],
        expects: :arg,
      }
    end

    let(:callable) do
      -> { expose :num, arg * 10 }
    end

    it "works correctly" do
      expect(axn.call).not_to be_ok
      expect(axn.call.error).to eq("error")

      expect(axn.call(arg: 1)).to be_ok
      expect(axn.call(arg: 1).success).to eq("success")
      expect(axn.call(arg: 1).num).to eq(10)
    end

    context "with a semi-complex expects" do
      let(:kwargs) do
        {
          expects: { arg: { type: Numeric, numericality: { greater_than: 1 } } },
          exposes: [:num],
        }
      end

      it "works correctly" do
        expect(axn.call(bar: 1, arg: 1)).not_to be_ok
        expect(axn.call(bar: 1, arg: 2)).to be_ok
      end
    end

    context "with a complex expects" do
      let(:kwargs) do
        {
          expects: [:bar, { arg: { type: Numeric, numericality: { greater_than: 1 } } }],
          exposes: [:num],
        }
      end

      it "works correctly" do
        expect(axn.call(bar: 1, arg: 1)).not_to be_ok
        expect(axn.call(bar: 1, arg: 2)).to be_ok
      end
    end
  end

  context "setting before, after, around hooks" do
    let(:before) { -> { puts "before" } }
    let(:after) { -> { puts "after" } }
    let(:rollback) { -> { puts "rollback" } }
    let(:around) do
      lambda { |block|
        puts "<<"
        block.call
        puts ">>"
      }
    end

    let(:callable) do
      -> { puts "call" }
    end

    let(:kwargs) do
      { before:, after:, around:, rollback: }
    end

    context "when ok?" do
      let(:expected) do
        %w[<< before call after >>].join("\n") + "\n" # rubocop:disable Style/StringConcatenation
      end

      it "executes hooks in order" do
        expect do
          expect(axn.call).to be_ok
        end.to output(expected).to_stdout
      end
    end

    context "when not ok?" do
      let(:expected) do
        %w[<< before call rollback].join("\n") + "\n" # rubocop:disable Style/StringConcatenation
      end

      let(:callable) do
        lambda {
          puts "call"
          raise "bad"
        }
      end

      it "executes hooks in order" do
        pending "TODO: implement #rollback"

        expect do
          expect(axn.call).not_to be_ok
        end.to output(expected).to_stdout
      end
    end
  end

  %i[error_from rescues].each do |setting|
    context "setting #{setting}" do
      let(:callable) do
        -> { raise "error" }
      end

      context "as hash" do
        let(:kwargs) do
          { setting => { -> { true } => "overridden msg" } }
        end

        it "works correctly" do
          expect(axn.call.error).to eq("overridden msg")
        end
      end

      context "as array" do
        let(:kwargs) do
          { setting => [-> { true }, "overridden msg"] }
        end

        it "works correctly" do
          expect(axn.call.error).to eq("overridden msg")
        end
      end
    end
  end
end

RSpec.describe Axn::Factory do
  let(:builder) { -> { Axn::Factory.build(**kwargs, &callable) } }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"
end

RSpec.describe "Axn()" do
  let(:builder) { -> { Axn(callable, **kwargs) } }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"

  context "when already Axn" do
    subject(:axn) { builder.call }
    let(:callable) { build_action { log "in action" } }

    it "returns the Axn" do
      expect(Axn::Factory).not_to receive(:build)

      expect(callable < Action).to eq(true)
      expect(axn < Action).to eq(true)
      expect(axn.call).to be_ok
    end
  end
end
