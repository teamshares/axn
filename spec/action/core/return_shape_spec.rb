# frozen_string_literal: true

RSpec.describe Action do
  describe "return shape" do
    subject { action.call }

    context "when successful" do
      let(:action) { build_action {} }

      it "is ok" do
        is_expected.to be_ok
      end
    end

    context "when fail! (user facing error)" do
      let(:action) do
        build_action do
          def call
            fail!("User-facing error")
          end
        end
      end

      it "is not ok" do
        is_expected.not_to be_ok
        expect(subject.error).to eq("User-facing error")
        expect(subject.exception).to be_nil
      end
    end

    context "when exception raised" do
      let(:action) do
        build_action do
          def call
            raise "Some internal issue!"
          end
        end
      end

      it "is not ok" do
        expect { subject }.not_to raise_error
        is_expected.not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(RuntimeError)
        expect(subject.exception.message).to eq("Some internal issue!")
      end
    end
  end
end
