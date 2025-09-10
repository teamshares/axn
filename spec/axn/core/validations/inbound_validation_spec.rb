# frozen_string_literal: true

RSpec.describe Axn do
  describe "inbound validation" do
    let(:action) do
      build_axn do
        expects :foo, type: Numeric, numericality: { greater_than: 10 }
      end
    end

    context "success" do
      subject { action.call(foo: 11, bar: 5, baz: 1) }

      it { is_expected.to be_ok }
    end

    context "contract failure" do
      subject { action.call(foo: 9, bar: 5, baz: 1) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo must be greater than 10")
      end
    end

    context "with missing inbound args" do
      subject { action.call(bar: 12, baz: 13) }

      it "fails inbound" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
      end
    end

    context "with outbound missing" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, numericality: { greater_than: 10 }
          exposes :bar
        end
      end

      subject { action.call(foo: 11, baz: 13) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::OutboundValidationError)
      end
    end

    context "allow_blank is passed to further validators as well" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, numericality: { greater_than: 10 }, allow_blank: true
          exposes :bar, allow_blank: true
        end
      end

      subject { action.call(baz: 13) }

      it { is_expected.to be_ok }
    end

    context "inbound defaults" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, default: 99
          exposes :foo
        end
      end

      context "when field is missing" do
        subject { action.call }

        it "applies default" do
          is_expected.to be_ok
          expect(subject.foo).to eq 99
        end
      end

      context "when field is explicitly nil" do
        subject { action.call(foo: nil) }

        it "applies default" do
          is_expected.to be_ok
          expect(subject.foo).to eq 99
        end
      end

      context "when field has a value" do
        subject { action.call(foo: 42) }

        it "preserves existing value" do
          is_expected.to be_ok
          expect(subject.foo).to eq 42
        end
      end
    end

    context "multiple fields validations per call" do
      let(:action) do
        build_axn do
          expects :foo, :bar, type: { with: Numeric, message: "should numberz" }
        end
      end

      context "when one invalid" do
        subject { action.call(foo: 1, bar: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Bar should numberz")
        end
      end

      context "when set" do
        subject { action.call(foo: 1, bar: 2) }

        it { is_expected.to be_ok }
      end
    end

    context "with multiple fields per expects line" do
      let(:action) do
        build_axn do
          expects :foo, :bar, type: Numeric
        end
      end

      context "when valid" do
        subject { action.call(foo: 1, bar: 2) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(foo: 1, bar: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Bar is not a Numeric")
        end
      end
    end

    context "with multiple expectations on the same field" do
      let(:action) do
        build_axn do
          expects :foo, type: String
          expects :foo, numericality: { greater_than: 10 }
        end
      end

      it "raises" do
        expect { action.call(foo: 100) }.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
      end
    end
  end
end
