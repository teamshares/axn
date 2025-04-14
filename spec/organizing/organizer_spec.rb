# frozen_string_literal: true

require_relative "../fixtures/date_organizer"

RSpec.describe "Organizing" do
  describe "standalone parsing" do
    subject { DateParser.call(date:) }

    context "with valid date" do
      let(:date) { "2020-01-01" }

      it { is_expected.to be_ok }
      it { expect(subject.date).to eq(Date.new(2020, 1, 1)) }
    end

    context "with invalid date" do
      let(:date) { "2020-01-32" }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("Parsing the date went poorly") }
      it { expect(subject.exception.class).to eq(Date::Error) }
      it { expect(subject.exception.message).to eq("invalid date") }
    end
  end

  describe "standalone checking" do
    subject { DateEvaluator.call(date:) }

    context "with date in 2020" do
      let(:date) { Date.new(2020, 1, 1) }

      it { is_expected.to be_ok }
      it { expect(subject.year).to eq(2020) }
    end

    context "with invalid date type" do
      let(:date) { "2020-01-01" }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("Something went wrong") }
      it { expect(subject.exception.message).to eq("Date is not a Date") }
    end
  end

  describe "vanilla organizer [NOT recommended]" do
    subject { VanillaOrganizer.call(date:) }

    context "with valid date" do
      let(:date) { "2020-01-01" }

      it { is_expected.to be_success }
      it { expect(subject.date).to be_a(Date) }

      it "can access all fields" do
        expect(subject.year).to eq(2020)
      end
    end

    context "with non-string date" do
      let(:date) { Date.parse("2020-01-01") }

      it { expect { subject }.to raise_error(Action::InboundValidationError, "Date is not a String") }
    end

    context "with invalid date string" do
      let(:date) { "a string" }

      it { expect { subject }.to raise_error(Date::Error, "invalid date") }
    end
  end

  describe "organizer" do
    subject { ServiceActionOrganizer.call(date:) }

    context "with valid date" do
      let(:date) { "2020-01-01" }

      it { is_expected.to be_ok }
      it { expect(subject.year).to eq(2020) }

      it "cannot access non-declared fields" do
        expect { subject.date }.to raise_error(Action::ContractViolation::MethodNotAllowed)
      end
    end

    context "with non-string date" do
      let(:date) { Date.parse("2020-01-01") }

      it { is_expected.not_to be_ok }
      it { expect(subject.exception.message).to eq("Date is not a String") }
    end

    context "with invalid date string" do
      let(:date) { "a string" }

      it { is_expected.not_to be_ok }
      it { expect(subject.error).to eq("Parsing the date went poorly") }
      it { expect(subject.exception.class).to eq(Date::Error) }
    end
  end
end
