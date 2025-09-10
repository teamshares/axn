# frozen_string_literal: true

RSpec.describe Axn do
  describe "preprocessing" do
    let(:action) do
      build_axn do
        expects :date_as_date, type: Date, preprocess: ->(raw) { Date.parse(raw) }
        exposes :date_as_date

        def call
          expose date_as_date:
        end
      end
    end

    context "when preprocessing is successful" do
      subject { action.call(date_as_date: "2020-01-01") }

      it "modifies the context" do
        is_expected.to be_ok
        expect(subject.date_as_date).to be_a(Date)
      end
    end

    context "when preprocessing fails" do
      subject { action.call(date_as_date: "") }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the cause to the original exception" do
        expect(subject.exception.cause).to be_a(ArgumentError)
        expect(subject.exception.cause.message).to include("invalid date")
      end
    end
  end
end
