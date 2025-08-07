# frozen_string_literal: true

RSpec.describe "Action spec helpers" do
  describe "Action::Result.ok" do
    context "bare" do
      subject(:result) { Action::Result.ok }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("Action completed successfully") }
    end

    context "allow blank exposures" do
      subject(:result) { Action::Result.ok(still_exposable: "", another: nil) }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("Action completed successfully") }
      it { expect(result.still_exposable).to eq("") }
      it { expect(result.another).to be_nil }
    end

    context "with custom message and exposure" do
      subject(:result) { Action::Result.ok("optional success message", custom_exposure: 123) }

      it { is_expected.to be_ok }
      it { expect(result.success).to eq("optional success message") }
      it { expect(result.custom_exposure).to eq(123) }
    end
  end

  describe "Action::Result.error" do
    context "bare" do
      subject(:result) { Action::Result.error }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Something went wrong") }
    end

    context "with custom message and exposure" do
      subject(:result) { Action::Result.error("Custom error message", still_exposable: 456) }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Custom error message") }
      it { expect(result.exception).to be_nil }
      it { expect(result.still_exposable).to eq(456) }
    end

    context "allow blank exposures" do
      subject(:result) { Action::Result.error(still_exposable: "", another: nil) }

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("Something went wrong") }
      it { expect(result.exception).to be_nil }
      it { expect(result.still_exposable).to eq("") }
      it { expect(result.another).to be_nil }
    end

    context "with exception" do
      subject(:result) do
        Action::Result.error("default msg", still_exposable: 456) do
          raise StandardError, "Custom error message"
        end
      end

      it { is_expected.not_to be_ok }
      it { expect(result.error).to eq("default msg") }
      it { expect(result.exception).to be_a(StandardError) }
      it { expect(result.exception.message).to eq("Custom error message") }
      it { expect(result.still_exposable).to eq(456) }
    end
  end

  describe "Action::Result#outcome" do
    it "returns success for ok results" do
      expect(Action::Result.ok.outcome).to eq(Action::Result::OUTCOME_SUCCESS)
    end

    it "returns failure for error results" do
      expect(Action::Result.error.outcome).to eq(Action::Result::OUTCOME_FAILURE)
    end

    it "returns exception for results with exceptions" do
      result = Action::Result.error { raise "error" }
      expect(result.outcome).to eq(Action::Result::OUTCOME_EXCEPTION)
    end
  end
end
