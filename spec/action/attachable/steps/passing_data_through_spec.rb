# frozen_string_literal: true

RSpec.describe Action::Attachable::Steps do
  subject(:result) { composed.call(num: 10, extra: 11) }

  let(:composed) do
    build_action do
      expects :num
      exposes :num, :third

      step :step1, expects: [:num], exposes: [:num] do
        puts "Step1:#{num}"
        expose :num, num + 1
      end

      step :step2, expects: %i[num extra], exposes: :num do
        puts "Step2:#{num}"

        # Note we can expect things from what was given to parent, NOT needed to be passed by prev step
        expose :num, num + extra
      end

      step :step3, expects: [:num], expose_return_as: :third do
        puts "Step3:#{num}"
        3
      end
    end
  end

  it "can pass data through the stack" do
    expect { result }.to output("Step1:10\nStep2:11\nStep3:22\n").to_stdout
    is_expected.to be_ok
    expect(result.num).to eq(22)
    expect(result.third).to eq(3)
  end
end
