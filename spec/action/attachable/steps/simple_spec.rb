# frozen_string_literal: true

RSpec.describe Action::Attachable::Steps do
  subject(:result) { composed.call!(name: "bar") }

  shared_examples "a composed Axn" do
    it "executes steps in order" do
      expect { result }.to output("Step1:bar\nStep2:11\n").to_stdout
      is_expected.to be_ok
    end
  end

  context "when applied via .step" do
    let(:composed) do
      build_action do
        # TODO: careful specs around how to pass args into/out of steps + the overall component (issues with duplicate context keys)
        # exposes :num

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
      build_axn(expects: [:name], exposes: [:num]) do
        puts "Step1:#{name}"
        expose :num, 11
      end
    end

    let(:step2) do
      build_axn(expects: [:num]) do
        puts "Step2:#{num}"
      end
    end

    let(:composed) do
      stub_const("Step1", step1)
      stub_const("Step2", step2)

      build_action do
        steps(Step1, Step2)
      end
    end

    it_behaves_like "a composed Axn"
  end
end
