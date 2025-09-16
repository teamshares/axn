# frozen_string_literal: true

RSpec.describe Axn::Validators::TypeValidator do
  let(:allow_blank) { false }
  let(:allow_nil) { false }
  let(:type) { :boolean }
  let(:action) do
    build_axn.tap do |klass|
      klass.expects :foo, type:, allow_blank:, allow_nil:
    end
  end

  describe "type validation" do
    describe "standalone value format" do
      describe "boolean" do
        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).not_to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end

        context "and allow_nil" do
          let(:allow_nil) { true }

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: "")).not_to be_ok
          end
        end
      end

      describe "params" do
        let(:type) { :params }

        it "validates" do
          expect(action.call(foo: {})).to be_ok
          expect(action.call(foo: { key: "value" })).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: {})).to be_ok
            expect(action.call(foo: { key: "value" })).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).not_to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).not_to be_ok
          end
        end

        context "with ActionController::Parameters" do
          before do
            # Create a mock ActionController::Parameters class if not defined
            unless defined?(ActionController::Parameters)
              stub_const("ActionController::Parameters", Class.new(Hash) do
                def initialize(params = {})
                  super()
                  merge!(params)
                end
              end)
            end
          end

          it "validates ActionController::Parameters" do
            params = ActionController::Parameters.new(key: "value")
            expect(action.call(foo: params)).to be_ok
          end
        end
      end

      describe "uuid" do
        let(:type) { :uuid }

        it "validates" do
          expect(action.call(foo: "123e4567-e89b-12d3-a456-426614174000")).to be_ok
          expect(action.call(foo: "123e4567e89b12d3a456426614174000")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: "abcabc")).not_to be_ok
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: "123e4567-e89b-12d3-a456-426614174000")).to be_ok
            expect(action.call(foo: "123e4567e89b12d3a456426614174000")).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: "abcabc")).not_to be_ok
          end
        end
      end

      describe "class types" do
        let(:type) { String }

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: "")).to be_ok

            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).not_to be_ok
          end
        end
      end

      describe "array of types" do
        let(:type) { [String, Numeric] }

        context "when valid" do
          subject { action.call(foo: 123) }

          it { is_expected.to be_ok }
        end

        context "when invalid" do
          subject { action.call(foo: Object.new) }

          it "fails" do
            expect(subject).not_to be_ok
            expect(subject.exception).to be_a(Axn::InboundValidationError)
            expect(subject.exception.message).to eq("Foo is not one of String, Numeric")
          end
        end

        context "when false" do
          subject { action.call(foo: false) }

          it "fails" do
            expect(subject).not_to be_ok
            expect(subject.exception).to be_a(Axn::InboundValidationError)
            expect(subject.exception.message).to eq("Foo is not one of String, Numeric and Foo can't be blank")
          end
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: 123)).to be_ok
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok  # Empty string is a valid String
            expect(action.call(foo: Object.new)).not_to be_ok
          end
        end
      end
    end

    describe "hash format with with key" do
      let(:message) { nil }
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :foo, type: { klass: type, message: }, allow_blank:
        end
      end

      describe "boolean" do
        let(:type) { :boolean }

        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
        end

        context "with custom message" do
          let(:message) { "must be true or false" }

          it "uses custom message" do
            result = action.call(foo: 1)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be true or false")
          end
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: true)).to be_ok
            expect(action.call(foo: false)).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).not_to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end
      end

      describe "params" do
        let(:type) { :params }

        it "validates" do
          expect(action.call(foo: {})).to be_ok
          expect(action.call(foo: { key: "value" })).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: {})).to be_ok
            expect(action.call(foo: { key: "value" })).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).not_to be_ok
            expect(action.call(foo: 1)).not_to be_ok
            expect(action.call(foo: [])).not_to be_ok
          end
        end
      end

      describe "class types" do
        let(:type) { String }

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: [])).not_to be_ok
        end

        context "with custom message" do
          let(:message) { "must be a string" }

          it "uses custom message" do
            result = action.call(foo: 1)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be a string")
          end
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok
            expect(action.call(foo: [])).not_to be_ok
            expect(action.call(foo: 1)).not_to be_ok
          end
        end
      end

      describe "array of types" do
        let(:type) { [String, Numeric] }

        it "validates" do
          expect(action.call(foo: "hello")).to be_ok
          expect(action.call(foo: 123)).to be_ok

          expect(action.call(foo: nil)).not_to be_ok
          expect(action.call(foo: Object.new)).not_to be_ok
        end

        context "with custom message" do
          let(:message) { "must be string or number" }

          it "uses custom message" do
            result = action.call(foo: Object.new)
            expect(result).not_to be_ok
            expect(result.exception.message).to eq("Foo must be string or number")
          end
        end

        context "and allow_blank" do
          let(:allow_blank) { true }

          it "validates" do
            expect(action.call(foo: "hello")).to be_ok
            expect(action.call(foo: 123)).to be_ok
            expect(action.call(foo: nil)).to be_ok
            expect(action.call(foo: "")).to be_ok  # Empty string is a valid String
            expect(action.call(foo: Object.new)).not_to be_ok
          end
        end
      end
    end

    describe "boolean defaults with explicit false values" do
      context "default: false should not override explicit false" do
        let(:action) do
          build_axn do
            expects :is_retirement_age, :has_tenure, type: :boolean, default: false
            exposes :is_retirement_age, :has_tenure, type: :boolean

            def call
              expose :is_retirement_age, is_retirement_age
              expose :has_tenure, has_tenure
            end
          end
        end

        it "preserves explicit false values" do
          result = action.call(is_retirement_age: false, has_tenure: false)

          expect(result).to be_ok
          expect(result.is_retirement_age).to be false
          expect(result.has_tenure).to be false
        end

        it "applies defaults when not provided" do
          result = action.call

          expect(result).to be_ok
          expect(result.is_retirement_age).to be false
          expect(result.has_tenure).to be false
        end

        it "preserves explicit true values" do
          result = action.call(is_retirement_age: true, has_tenure: true)

          expect(result).to be_ok
          expect(result.is_retirement_age).to be true
          expect(result.has_tenure).to be true
        end
      end

      context "default: true should not override explicit false" do
        let(:action) do
          build_axn do
            expects :is_enabled, type: :boolean, default: true
            exposes :is_enabled, type: :boolean

            def call
              expose :is_enabled, is_enabled
            end
          end
        end

        it "preserves explicit false values" do
          result = action.call(is_enabled: false)

          expect(result).to be_ok
          expect(result.is_enabled).to be false
        end

        it "applies default when not provided" do
          result = action.call

          expect(result).to be_ok
          expect(result.is_enabled).to be true
        end

        it "preserves explicit true values" do
          result = action.call(is_enabled: true)

          expect(result).to be_ok
          expect(result.is_enabled).to be true
        end
      end
    end
  end

  describe "regression tests for corrected allow_blank logic" do
    # These tests ensure that allow_blank only skips validation for nil values,
    # not all blank values, preventing regression of the corrected logic

    describe "Hash type with allow_blank" do
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :data, type: { klass: Hash }, allow_blank: true
        end
      end

      it "validates empty hash as valid Hash type" do
        expect(action.call(data: {})).to be_ok
      end

      it "validates non-empty hash as valid Hash type" do
        expect(action.call(data: { key: "value" })).to be_ok
      end

      it "skips validation for nil when allow_blank is true" do
        expect(action.call(data: nil)).to be_ok
      end

      it "validates empty string as invalid Hash type (not nil)" do
        expect(action.call(data: "")).not_to be_ok
        expect(action.call(data: "").exception.message).to include("is not a Hash")
      end

      it "validates false as invalid Hash type (not nil)" do
        expect(action.call(data: false)).not_to be_ok
        expect(action.call(data: false).exception.message).to include("is not a Hash")
      end

      it "validates empty array as invalid Hash type (not nil)" do
        expect(action.call(data: [])).not_to be_ok
        expect(action.call(data: []).exception.message).to include("is not a Hash")
      end
    end

    describe "String type with allow_blank" do
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :name, type: { klass: String }, allow_blank: true
        end
      end

      it "validates non-empty string as valid String type" do
        expect(action.call(name: "hello")).to be_ok
      end

      it "skips validation for nil when allow_blank is true" do
        expect(action.call(name: nil)).to be_ok
      end

      it "validates empty string as valid String type (correct type, just blank)" do
        expect(action.call(name: "")).to be_ok
      end

      it "validates false as invalid String type (not nil)" do
        expect(action.call(name: false)).not_to be_ok
        expect(action.call(name: false).exception.message).to include("is not a String")
      end

      it "validates number as invalid String type (not nil)" do
        expect(action.call(name: 123)).not_to be_ok
        expect(action.call(name: 123).exception.message).to include("is not a String")
      end
    end

    describe "Boolean type with allow_blank" do
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :flag, type: { klass: :boolean }, allow_blank: true
        end
      end

      it "validates true as valid boolean type" do
        expect(action.call(flag: true)).to be_ok
      end

      it "validates false as valid boolean type" do
        expect(action.call(flag: false)).to be_ok
      end

      it "skips validation for nil when allow_blank is true" do
        expect(action.call(flag: nil)).to be_ok
      end

      it "validates empty string as invalid boolean type (not nil)" do
        expect(action.call(flag: "")).not_to be_ok
        expect(action.call(flag: "").exception.message).to include("is not a boolean")
      end

      it "validates number as invalid boolean type (not nil)" do
        expect(action.call(flag: 1)).not_to be_ok
        expect(action.call(flag: 1).exception.message).to include("is not a boolean")
      end
    end

    describe "Array type with allow_blank" do
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :items, type: { klass: Array }, allow_blank: true
        end
      end

      it "validates non-empty array as valid Array type" do
        expect(action.call(items: [1, 2, 3])).to be_ok
      end

      it "validates empty array as valid Array type (correct type, just blank)" do
        expect(action.call(items: [])).to be_ok
      end

      it "skips validation for nil when allow_blank is true" do
        expect(action.call(items: nil)).to be_ok
      end

      it "validates empty string as invalid Array type (not nil)" do
        expect(action.call(items: "")).not_to be_ok
        expect(action.call(items: "").exception.message).to include("is not a Array")
      end

      it "validates hash as invalid Array type (not nil)" do
        expect(action.call(items: {})).not_to be_ok
        expect(action.call(items: {}).exception.message).to include("is not a Array")
      end
    end

    describe "Multiple types with allow_blank" do
      let(:action) do
        build_axn.tap do |klass|
          klass.expects :value, type: { klass: [String, Hash] }, allow_blank: true
        end
      end

      it "validates string as valid type" do
        expect(action.call(value: "hello")).to be_ok
      end

      it "validates hash as valid type" do
        expect(action.call(value: { key: "value" })).to be_ok
      end

      it "validates empty string as valid String type" do
        expect(action.call(value: "")).to be_ok
      end

      it "validates empty hash as valid Hash type" do
        expect(action.call(value: {})).to be_ok
      end

      it "skips validation for nil when allow_blank is true" do
        expect(action.call(value: nil)).to be_ok
      end

      it "validates false as invalid type (not nil)" do
        expect(action.call(value: false)).not_to be_ok
        expect(action.call(value: false).exception.message).to include("is not one of String, Hash")
      end

      it "validates array as invalid type (not nil)" do
        expect(action.call(value: [])).not_to be_ok
        expect(action.call(value: []).exception.message).to include("is not one of String, Hash")
      end

      it "validates whitespace strings as valid (they are valid Strings)" do
        expect(action.call(value: "   ")).to be_ok  # whitespace
        expect(action.call(value: "\n")).to be_ok   # newline
        expect(action.call(value: "\t")).to be_ok   # tab
        expect(action.call(value: " \n ")).to be_ok # mixed whitespace
      end
    end
  end
end
