# frozen_string_literal: true

RSpec.describe Action do
  describe ".expects" do
    context "with non-reserved attribute names" do
      let(:action) do
        build_action do
          expects :success, type: String
        end
      end

      it { expect { action.call(success: "whoa") }.not_to raise_error }
    end

    context "with reserved attribute names" do
      let(:action) do
        build_action do
          expects :default_error, type: String
        end
      end

      it { expect { action.call(default_error: "whoa") }.to raise_error(Action::ContractViolation::ReservedAttributeError) }
    end
  end

  describe ".exposes" do
    subject(:result) { action.call }

    context "with non-reserved attribute names" do
      let(:action) do
        build_action do
          exposes :some_field, allow_blank: true
        end
      end

      it { is_expected.to be_success }
    end

    context "with reserved attribute names" do
      let(:action) do
        build_action do
          exposes :success, allow_blank: true
        end
      end

      it { expect { subject }.to raise_error(Action::ContractViolation::ReservedAttributeError) }
    end
  end
end
