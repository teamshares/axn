# frozen_string_literal: true

RSpec.describe Action::Attachable::Steps do
  subject(:result) { composed.call(num: 10, extra: 11) }

  let(:composed) do
    build_action do
      expects :num
      exposes :num

      step :step1, expects: [:num], exposes: [:num] do
        puts "Step1:#{num}"
        expose :num, num + 1
      end

      step :step2, expects: %i[num extra] do
        puts "Step2:#{num}"

        # Note we can expect things from what was given to parent, NOT needed to be passed by prev step
        expose :num, num + extra
      end
    end
  end

  it "can pass data through the stack" do
    pending "TODO: finalize support for this"

    expect { result }.to output("Step1:10\nStep2:11\n").to_stdout
    is_expected.to be_ok
    expect(result.num).to eq(22)
  end
end
