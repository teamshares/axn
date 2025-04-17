# frozen_string_literal: true

RSpec.describe "Action spec helpers" do
  describe "Action::Result.ok" do
    subject(:result) { Action::Result.ok }

    it { is_expected.to be_ok }
    it { expect(result.success).to eq("Action completed successfully") }
  end

  describe "Action::Result.error" do
    subject(:result) { Action::Result.error }

    it { is_expected.not_to be_ok }
    it { expect(result.error).to eq("Something went wrong") }

    context "with custom message" do
      subject(:result) { Action::Result.error("Custom error message") }

      it { expect(result.error).to eq("Custom error message") }
    end
  end
end
