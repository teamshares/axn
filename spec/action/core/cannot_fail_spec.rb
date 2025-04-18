# frozen_string_literal: true

RSpec.describe Action do
  context "calling fail! on context" do
    subject { action.call }

    let(:action) do
      build_action do
        def call
          context.fail!("User-facing error")
        end
      end
    end

    it "is prevented" do
      is_expected.not_to be_ok
      expect(subject.error).to eq("Something went wrong")
      expect(subject.exception).to be_a(Action::ContractViolation::MethodNotAllowed)
      expect(subject.exception.message).to eq "Call fail! directly rather than on the context"
    end
  end
end
