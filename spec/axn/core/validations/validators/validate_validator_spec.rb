# frozen_string_literal: true

RSpec.describe Axn::Validators::ValidateValidator do
  describe "custom validations" do
    let(:action) do
      build_axn do
        expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
      end
    end

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
      let(:action) do
        build_axn do
          expects :foo, validate: ->(_value) { raise "oops" }
        end
      end

      subject { action.call(foo: 20) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo failed validation: oops")
      end
    end

    context "and allow_blank" do
      let(:action) do
        build_axn do
          expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }, allow_blank: true
        end
      end

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end

    context "and allow_nil" do
      let(:action) do
        build_axn do
          expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }, allow_nil: true
        end
      end

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).not_to be_ok
      end
    end
  end

  describe "custom validations hash format" do
    let(:action) do
      build_axn do
        expects :foo, validate: { with: ->(value) { "must be pretty big" unless value > 10 } }
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
      let(:action) do
        build_axn do
          expects :foo, validate: { with: ->(value) { "custom error" unless value > 10 } }
        end
      end

      it "uses custom message" do
        result = action.call(foo: 5)
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("Foo custom error")
      end
    end

    context "and allow_blank" do
      let(:action) do
        build_axn do
          expects :foo, validate: { with: ->(value) { "must be pretty big" unless value > 10 } }, allow_blank: true
        end
      end

      it "validates" do
        expect(action.call(foo: 20)).to be_ok
        expect(action.call(foo: 5)).not_to be_ok
        expect(action.call(foo: nil)).to be_ok
        expect(action.call(foo: "")).to be_ok
      end
    end
  end

  describe "Axn::Internal::Logging.piping_error integration" do
    let(:action) do
      build_axn do
        expects :foo, validate: { with: ->(_v) { raise ArgumentError, "fail message" } }
      end
    end

    before do
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when custom validation raises" do
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
