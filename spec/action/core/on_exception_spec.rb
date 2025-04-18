# frozen_string_literal: true

RSpec.describe Action do
  describe "#on_exception" do
    subject { action.call(name: "Foo", ssn: "abc", extra: "bang", outbound: 1) }

    before do
      allow(described_class.config).to receive(:on_exception)
    end

    let(:action) do
      build_action do
        expects :name
        expects :ssn, sensitive: true
        exposes :outbound

        def call
          raise "Some internal issue!"
        end
      end
    end

    let(:filtered_context) do
      { name: "Foo", ssn: "[FILTERED]", outbound: 1 }
    end

    it "is given a filtered context (sensitive values filtered + only declared inbound/outbound fields)" do
      expect(described_class.config).to receive(:on_exception).with(anything,
                                                                    action: action,
                                                                    context: filtered_context).and_call_original
      is_expected.not_to be_ok
    end
  end

  describe "#try" do
    subject { action.call }

    let(:action) do
      build_action do
        expects :should_fail, allow_blank: true, default: false

        def call
          try do
            fail! "allow intentional failure to bubble" if should_fail
            raise "Some internal issue!"
          end
        end
      end
    end

    it "calls on_exception but doesn't fail action" do
      expect(described_class.config).to receive(:on_exception).once
      is_expected.to be_ok
    end

    context "with an explicit fail!" do
      subject { action.call(should_fail: true) }

      it "allows the failure to bubble up" do
        expect(described_class.config).not_to receive(:on_exception)
        is_expected.not_to be_ok
        expect(subject.error).to eq("allow intentional failure to bubble")
      end
    end
  end
end
