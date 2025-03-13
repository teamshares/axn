# frozen_string_literal: true

RSpec.describe Action do
  describe "inbound validation" do
    let(:action) do
      build_action do
        expects :foo, type: Numeric, numericality: { greater_than: 10 }
      end
    end

    context "success" do
      subject { action.call(foo: 11, bar: 5, baz: 1) }

      it { is_expected.to be_success }
    end

    context "contract failure" do
      subject { action.call(foo: 9, bar: 5, baz: 1) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Action::ContractViolation::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo must be greater than 10")
      end
    end
  end

  describe "outbound validation" do
    let(:action) do
      build_action do
        exposes :bar, type: Numeric, numericality: { greater_than: 10 }
        exposes :qux, type: Numeric

        def call
          expose :qux, 99
        end
      end
    end

    context "success" do
      subject(:result) { action.call(foo: 10, bar: 11, baz: 1) }

      it { is_expected.to be_success }

      it "exposes existing context" do
        expect(subject.bar).to eq(11)
      end

      it "exposes new values" do
        expect(subject.qux).to eq(99)
      end

      it "prevents external access of non-exposed values" do
        expect { result.foo }.to raise_error(Action::ContractViolation::MethodNotAllowed)
      end
    end

    context "contract failure" do
      subject { action.call(foo: 10, bar: 9, baz: 1) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Action::ContractViolation::OutboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Bar must be greater than 10")
      end
    end

    context "setting failure" do
      subject { action.call(foo: 10, bar: 11, baz: 1) }

      let(:action) do
        build_action do
          exposes :bar, type: Numeric, numericality: { greater_than: 10 }

          def call
            expose :qux, 99
          end
        end
      end

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Action::ContractViolation::InvalidExposure)
      end
    end
  end

  describe "complex validation" do
    let(:action) do
      build_action do
        expects :foo, type: String
        exposes :bar, type: String
      end
    end

    context "success" do
      subject { action.call(foo: "a", bar: "b", baz: "c") }

      it { is_expected.to be_success }
    end

    context "failure" do
      subject { action.call(foo: 1, bar: 2, baz: 3) }

      it "fails" do
        expect(subject).to be_failure
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Action::ContractViolation::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo is not a String")
      end
    end
  end
end
