# frozen_string_literal: true

RSpec.describe "Step functionality" do
  subject(:result) { composed.call!(name: "bar") }

  shared_examples "a composed Axn" do
    it "executes steps in order" do
      expect { result }.to output("Step1:bar\nStep2:11\n").to_stdout
      is_expected.to be_ok
      expect(result.num).to eq(11)
    end
  end

  context "when applied via .step" do
    let(:composed) do
      build_axn do
        exposes :num

        step :step1, expects: [:name], exposes: [:num] do
          puts "Step1:#{name}"
          expose :num, 11
        end

        step :step2, expects: [:num] do
          puts "Step2:#{num}"
        end
      end
    end

    it_behaves_like "a composed Axn"
  end

  context "when applied via .steps" do
    let(:step1) do
      Axn::Factory.build(expects: [:name], exposes: [:num]) do
        puts "Step1:#{name}"
        expose :num, 11
      end
    end

    let(:step2) do
      Axn::Factory.build(expects: [:num]) do
        puts "Step2:#{num}"
      end
    end

    let(:composed) do
      stub_const("Step1", step1)
      stub_const("Step2", step2)

      build_axn do
        exposes :num

        steps(Step1, Step2)
      end
    end

    it_behaves_like "a composed Axn"
  end

  describe "steps(...) grammar" do
    let(:step1) { Axn::Factory.build(expects: [:name]) {} }
    let(:step2) { Axn::Factory.build {} }

    # The regression this closes: `steps [Step1, Step2]` (an Array handed to the splat instead of
    # `steps Step1, Step2`) used to be silently SKIPPED (`next unless step_class.is_a?(Class)`) -- the
    # action mounted zero steps and settled `success`, having done nothing, with no complaint at all.
    it "rejects an Array handed to the splat instead of variadic classes" do
      s1 = step1
      s2 = step2
      expect do
        build_axn { steps([s1, s2]) }
      end.to raise_error(ArgumentError, /steps must be Axn classes/)
    end

    it "tolerates a nil entry (e.g. a conditional step)" do
      s1 = step1
      expect { build_axn { steps(s1, nil) } }.not_to raise_error
    end

    # Codex review, PR #272: the rejection message interpolated `step_class.inspect`, so a hostile
    # step value's own `#inspect` raising would replace the intended declaration-time ArgumentError.
    it "does not let a hostile #inspect replace the intended ArgumentError" do
      hostile = Object.new
      def hostile.inspect = raise "boom in inspect"

      expect do
        build_axn { steps(hostile) }
      end.to raise_error(ArgumentError, /steps must be Axn classes/)
    end
  end
end
