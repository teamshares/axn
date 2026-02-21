# frozen_string_literal: true

RSpec.describe Axn::Validators::ValidateValidator do
  let(:allow_blank) { false }
  let(:allow_nil) { false }
  let(:validator) { ->(value) { "must be pretty big" unless value > 10 } }
  let(:action) do
    build_axn.tap do |klass|
      klass.expects :foo, validate: validator, allow_blank:, allow_nil:
    end
  end

  describe "custom validations" do
    context "when valid" do
      subject { action.call(foo: 20) }

      it { is_expected.to be_ok }
    end

    context "when invalid" do
      subject { action.call(foo: 10) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo must be pretty big")
      end
    end

    context "when validator raises" do
      let(:validator) { ->(_value) { raise "oops" } }

      subject { action.call(foo: 20) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo failed validation: oops")
      end
    end

    context "and allow_blank" do
      let(:allow_blank) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end

    context "and allow_nil" do
      let(:allow_nil) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).not_to be_ok
      end
    end
  end

  describe "custom validations hash format" do
    let(:message) { nil }
    let(:action) do
      build_axn.tap do |klass|
        klass.expects :foo, validate: { with: validator, message: }, allow_blank:, allow_nil:
      end
    end

    context "when valid" do
      subject { action.call(foo: 20) }

      it { is_expected.to be_ok }
    end

    context "when invalid" do
      subject { action.call(foo: 5) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo must be pretty big")
      end
    end

    context "with custom message" do
      let(:validator) { ->(value) { "custom error" unless value > 10 } }

      it "uses custom message" do
        result = action.call(foo: 5)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("Foo custom error")
      end
    end

    context "and allow_blank" do
      let(:allow_blank) { true }

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end
  end

  describe "Axn::Internal::PipingError.piping_error integration" do
    let(:validator) { ->(_v) { raise ArgumentError, "fail message" } }

    before do
      allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original
    end

    it "calls Axn::Internal::PipingError.piping_error when custom validation raises" do
      result = action.call(foo: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect_piping_error_called(
        message_substring: "applying custom validation",
        error_class: ArgumentError,
        error_message: "fail message",
      )
    end
  end
end
