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
          expects :fail!, type: String
        end
      end

      it { expect { action.call }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
    end

    context "with other reserved expectation field names" do
      %w[_default_success _action_name _msg_resolver].each do |field_name|
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

  # The facade's own plumbing used to occupy these (PRO-3423): `context`, `action`, `action_name`,
  # `declared_fields` and the `default_*` pair were refused because ContextFacade/InternalContext
  # happened to answer to them, while being private, undocumented and unreachable from an action.
  describe ".expects with a name the facade's internals used to claim" do
    %w[context action action_name declared_fields default_error default_success].each do |field_name|
      context "with #{field_name}" do
        let(:action) do
          build_axn do
            expects field_name.to_sym, type: String
          end
        end

        it { expect { action.call(field_name.to_sym => "whoa") }.not_to raise_error }
      end
    end

    # The half that has to keep working: the action-side `default_error` sugar now dispatches
    # `_default_error` on the facade, so a rename that missed this would answer nil here.
    it "still answers the framework default in an action that declared no such field" do
      action = build_axn do
        exposes :probe
        def call = expose(probe: default_error)
      end

      expect(action.call.probe).to eq("Something went wrong")
    end

    # And the other half: on a class that DOES declare the field, the reader wins — the sugar is
    # surrenderable (Contract::InstanceMethods), so losing it is the documented trade, not a bug.
    it "answers the caller's value in an action that declared a field of that name" do
      action = build_axn do
        expects :default_error, type: String
        exposes :probe

        def call = expose(probe: default_error)
      end

      expect(action.call(default_error: "mine").probe).to eq("mine")
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

    context "with other reserved field names" do
      # `standalone` is refused because it is a control kwarg on `fail!`/`done!`, which binds ahead of
      # their exposures: `fail!("msg", standalone: value)` would set the option and leave the exposure
      # unset. Read off those signatures rather than listed (Axn::Core::SETTLEMENT_CONTROL_KWARGS).
      %w[outcome exception elapsed_time finalized? __action__ __exposed_keys__ __declared_fields__ standalone].each do |field_name|
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
