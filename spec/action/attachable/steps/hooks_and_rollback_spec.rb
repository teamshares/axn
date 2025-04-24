# frozen_string_literal: true

RSpec.describe Action::Attachable::Steps do
  subject(:result) { composed.call(num:, extra: 11) }

  let(:composed) do
    build_action do
      expects :num

      before { puts "outer before with #{num}" }
      after { puts "outer after" }

      step :step1, expects: [:num], exposes: [:num], before: -> { puts "<1<" }, after: -> { puts ">1>" }, rollback: -> { puts "RB1" } do
        puts "Step1:#{num}"
        expose :num, num + 1
      end

      step :step2, expects: %i[num extra], exposes: :num, before: -> { puts "<2<" }, after: -> { puts ">2>" }, rollback: -> { puts "RB2" } do
        puts "Step2:#{num}"

        # Note we can expect things from what was given to parent, NOT needed to be passed by prev step
        expose :num, num + extra
      end

      step :step3, expects: [:num], rollback: -> { puts "RB3" } do
        puts "Step3:#{num}"
        raise "intentional failure" if num > 30
      end
    end
  end

  context "when ok?" do
    let(:num) { 10 }

    it "hooks look right" do
      expect { result }.to output("outer before with 10\n<1<\nStep1:10\n>1>\n<2<\nStep2:11\n>2>\nStep3:22\nouter after\n").to_stdout
      is_expected.to be_ok
    end
  end

  context "when not ok?" do
    let(:num) { 30 }

    it "rollbacks look right" do
      # TODO: once we roll back the *current* step, we should expect to see RB3 in here too
      expect { result }.to output("outer before with 30\n<1<\nStep1:30\n>1>\n<2<\nStep2:31\n>2>\nStep3:42\nRB2\nRB1\n").to_stdout
      is_expected.not_to be_ok
    end
  end
end
