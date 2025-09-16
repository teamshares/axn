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

    context "optional: true works like allow_blank: true" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, numericality: { greater_than: 10 }, optional: true
          exposes :bar, optional: true
        end
      end

      subject { action.call(baz: 13) }

      it { is_expected.to be_ok }
    end

    context "optional: true with different blank values" do
      let(:action) do
        build_axn do
          expects :name, type: String, optional: true
          exposes :name, optional: true
        end
      end

      context "when field is missing" do
        subject { action.call }

        it "passes validation" do
          is_expected.to be_ok
          expect(subject.name).to be_nil
        end
      end

      context "when field is nil" do
        subject { action.call(name: nil) }

        it "passes validation" do
          is_expected.to be_ok
          expect(subject.name).to be_nil
        end
      end

      context "when field is empty string" do
        subject { action.call(name: "") }

        it "passes validation" do
          is_expected.to be_ok
          expect(subject.name).to eq ""
        end
      end

      context "when field is whitespace" do
        subject { action.call(name: "   ") }

        it "passes validation" do
          is_expected.to be_ok
          expect(subject.name).to eq "   "
        end
      end

      context "when field has valid value" do
        subject { action.call(name: "John") }

        it "passes validation" do
          is_expected.to be_ok
          expect(subject.name).to eq "John"
        end
      end

      context "when field has invalid type" do
        subject { action.call(name: 123) }

        it "fails validation" do
          is_expected.not_to be_ok
          expect(subject.exception.message).to include("is not a String")
        end
      end
    end

    context "optional: true with allow_blank: true (both specified)" do
      let(:action) do
        build_axn do
          expects :foo, type: String, optional: true, allow_blank: true
        end
      end

      subject { action.call }

      it "works (allow_blank takes precedence)" do
        is_expected.to be_ok
      end
    end

    context "optional: true with allow_blank: false" do
      let(:action) do
        build_axn do
          expects :foo, type: String, optional: true, allow_blank: false
        end
      end

      subject { action.call }

      it "works (allow_blank takes precedence)" do
        is_expected.to be_ok
      end
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

    context "inbound defaults with blank values" do
      shared_examples "default behavior with blank values" do |default_value, allow_blank, expected_behavior|
        let(:action) do
          build_axn do
            expects(:field, type: String, default: default_value, allow_blank:)
            exposes :field, allow_blank:
          end
        end

        context "when field is missing" do
          subject { action.call }

          it "applies default and #{expected_behavior[:missing]}" do
            if expected_behavior[:missing][:success]
              is_expected.to be_ok
              expect(subject.field).to eq default_value
            else
              is_expected.not_to be_ok
              expect(subject.exception).to be_a(Axn::InboundValidationError)
              expect(subject.exception.message).to include("can't be blank")
            end
          end
        end

        context "when field is explicitly nil" do
          subject { action.call(field: nil) }

          it "applies default and #{expected_behavior[:nil]}" do
            if expected_behavior[:nil][:success]
              is_expected.to be_ok
              expect(subject.field).to eq default_value
            else
              is_expected.not_to be_ok
              expect(subject.exception).to be_a(Axn::InboundValidationError)
              expect(subject.exception.message).to include("can't be blank")
            end
          end
        end

        context "when field has blank string value" do
          subject { action.call(field: "") }

          it "preserves existing blank value and #{expected_behavior[:blank]}" do
            if expected_behavior[:blank][:success]
              is_expected.to be_ok
              expect(subject.field).to eq ""
            else
              is_expected.not_to be_ok
              expect(subject.exception).to be_a(Axn::InboundValidationError)
              expect(subject.exception.message).to include("can't be blank")
            end
          end
        end

        context "when field has non-blank value" do
          subject { action.call(field: "hello") }

          it "preserves existing value and passes validation" do
            is_expected.to be_ok
            expect(subject.field).to eq "hello"
          end
        end
      end

      context "with blank string default and allow_blank: true" do
        include_examples "default behavior with blank values", "", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with blank string default and allow_blank: false" do
        include_examples "default behavior with blank values", "", false, {
          missing: { success: false, description: "fails validation" },
          nil: { success: false, description: "fails validation" },
          blank: { success: false, description: "fails validation" },
        }
      end

      context "with non-blank default and allow_blank: true" do
        include_examples "default behavior with blank values", "default_value", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with non-blank default and allow_blank: false" do
        include_examples "default behavior with blank values", "default_value", false, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: false, description: "fails validation" },
        }
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
