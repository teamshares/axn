# frozen_string_literal: true

require "action/core/handle_exceptions"

RSpec.describe Action::HandleExceptions do
  describe "return shape" do
    subject(:result) { interactor.call }

    context "when successful" do
      let(:interactor) { build_interactor(described_class) {} }

      it "is ok" do
        is_expected.to be_success
      end
    end

    context "when fail! (user facing error)" do
      let(:interactor) do
        build_interactor(described_class) do
          def call
            fail!("User-facing error")
          end
        end
      end

      it "is not ok" do
        is_expected.not_to be_success
        expect(subject.exception).to be_nil

        # NOTE: only because the error message generation is defined on the ContextFacade layer,
        # which we're not pulling in for this set of specs.
        expect(subject.error).to be_nil
      end
    end

    context "when exception raised" do
      let(:interactor) do
        build_interactor(described_class) do
          def call
            raise "Some internal issue!"
          end
        end
      end

      it "is not ok" do
        expect { subject }.not_to raise_error
        is_expected.not_to be_success
        expect(subject.exception).to be_a(RuntimeError)
        expect(subject.exception.message).to eq("Some internal issue!")

        # NOTE: only because the error message generation is defined on the ContextFacade layer,
        # which we're not pulling in for this set of specs.
        expect(subject.error).to be_nil
      end
    end
  end
end
