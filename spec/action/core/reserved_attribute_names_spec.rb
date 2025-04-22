# frozen_string_literal: true

RSpec.describe Action do
  describe ".expects" do
    let(:action) do
      build_action do
        expects :success, type: String
      end
    end

    it "cannot expect reserved attribute names" do
      expect { action.call(success: "whoa") }.to raise_error(Action::ContractViolation::ReservedAttributeError)
    end
  end
end
