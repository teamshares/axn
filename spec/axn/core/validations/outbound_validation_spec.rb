# frozen_string_literal: true

RSpec.describe Axn do
  describe "outbound validation" do
    let(:action) do
      build_axn do
        exposes :bar, type: Numeric, numericality: { greater_than: 10 }
        exposes :qux, type: Numeric

        def call
          expose :qux, 99
        end
      end
    end

    context "success" do
      subject(:result) { action.call(foo: 10, bar: 11, baz: 1) }

      it { is_expected.to be_ok }

      it "exposes existing context" do
        expect(subject.bar).to eq(11)
      end

      it "exposes new values" do
        expect(subject.qux).to eq(99)
      end

      it "prevents external access of non-exposed values" do
        expect { result.foo }.to raise_error(Axn::ContractViolation::MethodNotAllowed)
      end
    end

    context "contract failure" do
      subject { action.call(foo: 10, bar: 9, baz: 1) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::OutboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Bar must be greater than 10")
      end
    end

    context "setting failure" do
      subject { action.call(foo: 10, bar: 11, baz: 1) }

      let(:action) do
        build_axn do
          exposes :bar, type: Numeric, numericality: { greater_than: 10 }

          def call
            expose :qux, 99
          end
        end
      end

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::ContractViolation::UnknownExposure)
      end
    end

    context "outbound defaults" do
      let(:action) do
        build_axn do
          exposes :foo, default: 99
        end
      end

      subject { action.call }

      it "are set correctly" do
        is_expected.to be_ok
        expect(subject.foo).to eq 99
      end
    end

    context "support optional outbound exposures" do
      let(:action) do
        build_axn do
          expects :foo, type: :boolean
          exposes :bar, allow_blank: true

          def call
            expose :bar, 99 if foo
          end
        end
      end

      context "when not set" do
        subject { action.call(foo: false) }

        it { is_expected.to be_ok }
      end

      context "when set" do
        subject { action.call(foo: true) }

        it { is_expected.to be_ok }
      end
    end

    context "with multiple fields per exposes line" do
      let(:action) do
        build_axn do
          expects :baz
          exposes :foo, :bar, type: Numeric

          def call
            expose foo: baz, bar: baz
          end
        end
      end

      context "when valid" do
        subject { action.call(baz: 100) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(baz: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::OutboundValidationError)
          expect(subject.exception.message).to eq("Foo is not a Numeric and Bar is not a Numeric")
        end
      end
    end

    context "with multiple expectations on the same field" do
      let(:action) do
        build_axn do
          exposes :foo, type: String
          exposes :foo, numericality: { greater_than: 10 }
        end
      end

      it "raises" do
        expect { action.call(baz: 100) }.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
      end
    end

    context "is accessible on internal context" do
      let(:action) do
        build_axn do
          exposes :foo, default: "bar"

          def call
            puts "Foo is: #{foo}"
          end
        end
      end

      subject { action.call }

      it "is accessible" do
        # TODO: if we apply defaults earlier, this would say bar
        expect { subject }.to output("Foo is: \n").to_stdout
        expect(subject).to be_ok
      end
    end

    context "with default that is a callable" do
      let(:action) do
        build_axn do
          exposes :foo, default: -> { "bar #{helper_method}" }

          private

          def helper_method = 123
        end
      end

      subject { action.call }

      it "has access to local helper methods" do
        expect(subject.foo).to eq "bar 123"
      end
    end

    describe "#expose" do
      let(:action) do
        build_axn do
          exposes :qux

          def call
            expose :qux, 11 # Just confirming can call twice
            expose :qux, 99
          end
        end
      end

      subject { action.call }

      it "can expose" do
        is_expected.to be_ok
        expect(subject.qux).to eq 99
      end
    end
  end
end
