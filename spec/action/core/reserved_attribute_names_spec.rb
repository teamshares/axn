# frozen_string_literal: true

RSpec.describe Axn do
  describe ".expects" do
    context "with non-reserved attribute names" do
      let(:action) do
        build_axn do
          expects :success, type: String
        end
      end

      it { expect { action.call(success: "whoa") }.not_to raise_error }
    end

    context "with reserved attribute names" do
      let(:action) do
        build_axn do
          expects :default_error, type: String
        end
      end

      it { expect { action.call(default_error: "whoa") }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
    end
  end

  describe ".exposes" do
    subject(:result) { action.call }

    context "with non-reserved attribute names" do
      let(:action) do
        build_axn do
          exposes :some_field, allow_blank: true
        end
      end

      it { is_expected.to be_ok }
    end

    context "with reserved attribute names" do
      let(:action) do
        build_axn do
          exposes :success, allow_blank: true
        end
      end

      it { expect { subject }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
    end
  end
end
