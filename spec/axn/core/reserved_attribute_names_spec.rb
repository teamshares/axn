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

    context "with other reserved expectation field names" do
      %w[default_success action_name].each do |field_name|
        context "with #{field_name}" do
          let(:action) do
            build_axn do
              expects field_name.to_sym, type: String
            end
          end

          it { expect { action.call(field_name.to_sym => "whoa") }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
        end
      end
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

    context "with result field name" do
      let(:action) do
        build_axn do
          exposes :result, allow_blank: true
        end
      end

      it { expect { subject }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
    end

    context "with other reserved field names" do
      %w[outcome exception elapsed_time finalized? __action__].each do |field_name|
        context "with #{field_name}" do
          let(:action) do
            build_axn do
              exposes field_name.to_sym, allow_blank: true
            end
          end

          it { expect { subject }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
        end
      end
    end
  end
end
