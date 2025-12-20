# frozen_string_literal: true

RSpec.describe Axn do
  describe "preprocessing" do
    let(:action) do
      build_axn do
        expects :date_as_date, type: Date, preprocess: ->(raw) { Date.parse(raw) }
        exposes :date_as_date

        def call
          expose date_as_date:
        end
      end
    end

    context "when preprocessing is successful" do
      subject { action.call(date_as_date: "2020-01-01") }

      it "modifies the context" do
        is_expected.to be_ok
        expect(subject.date_as_date).to be_a(Date)
      end
    end

    context "when preprocessing fails" do
      subject { action.call(date_as_date: "") }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the cause to the original exception" do
        expect(subject.exception.cause).to be_a(ArgumentError)
        expect(subject.exception.cause.message).to include("invalid date")
      end
    end

    context "when fail! is called in preprocess block" do
      let(:action) do
        build_axn do
          expects :value, preprocess: ->(_v) { fail!("Invalid value") }
          exposes :value

          def call
            expose value:
          end
        end
      end

      subject { action.call(value: "test") }

      it "fails with Axn::Failure" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::Failure)
        expect(subject.exception).not_to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the error message" do
        expect(subject.error).to eq("Invalid value")
      end

      it "triggers on_failure handlers, not on_exception" do
        failure_called = false
        exception_called = false

        action = build_axn do
          expects :value, preprocess: ->(_v) { fail!("Invalid value") }
          exposes :value

          on_failure { failure_called = true }
          on_exception { exception_called = true }

          def call
            expose value:
          end
        end

        action.call(value: "test")
        expect(failure_called).to be true
        expect(exception_called).to be false
      end
    end

    context "when done! is called in preprocess block" do
      let(:action) do
        build_axn do
          expects :value, preprocess: ->(_v) { done!("Early completion") }
          exposes :value

          def call
            expose value:
          end
        end
      end

      subject { action.call(value: "test") }

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "sets the success message" do
        expect(subject.success).to eq("Early completion")
      end

      it "triggers on_success handlers" do
        success_called = false

        action = build_axn do
          expects :value, preprocess: ->(_v) { done!("Early completion") }
          exposes :value

          on_success { success_called = true }

          def call
            expose value:
          end
        end

        result = action.call(value: "test")
        expect(result).to be_ok
        expect(success_called).to be true
      end

      it "does not execute call method" do
        call_executed = false

        action = build_axn do
          expects :value, preprocess: ->(_v) { done!("Early completion") }
          exposes :value

          define_method :call do
            call_executed = true
            expose value:
          end
        end

        action.call(value: "test")
        expect(call_executed).to be false
      end
    end
  end
end
