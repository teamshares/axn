# frozen_string_literal: true

RSpec.describe Axn do
  describe "default assignment" do
    context "when fail! is called in default block" do
      let(:action) do
        build_axn do
          expects :value, default: -> { fail!("Invalid default") }
          exposes :value

          def call
            expose value:
          end
        end
      end

      subject { action.call }

      it "fails with Axn::Failure" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::Failure)
        expect(subject.exception).not_to be_a(Axn::ContractViolation::DefaultAssignmentError)
      end

      it "sets the error message" do
        expect(subject.error).to eq("Invalid default")
      end

      it "triggers on_failure handlers, not on_exception" do
        failure_called = false
        exception_called = false

        action = build_axn do
          expects :value, default: -> { fail!("Invalid default") }
          exposes :value

          on_failure { failure_called = true }
          on_exception { exception_called = true }

          def call
            expose value:
          end
        end

        action.call
        expect(failure_called).to be true
        expect(exception_called).to be false
      end
    end

    context "when done! is called in default block" do
      let(:action) do
        build_axn do
          expects :value, default: -> { done!("Early completion") }
          exposes :value

          def call
            expose value:
          end
        end
      end

      subject { action.call }

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "sets the success message" do
        expect(subject.success).to eq("Early completion")
      end

      it "triggers on_success handlers" do
        success_called = false

        action = build_axn do
          expects :value, default: -> { done!("Early completion") }
          exposes :value

          on_success { success_called = true }

          def call
            expose value:
          end
        end

        result = action.call
        expect(result).to be_ok
        expect(success_called).to be true
      end

      it "does not execute call method" do
        call_executed = false

        action = build_axn do
          expects :value, default: -> { done!("Early completion") }
          exposes :value

          define_method :call do
            call_executed = true
            expose value:
          end
        end

        action.call
        expect(call_executed).to be false
      end
    end

    context "when fail! is called in subfield default block" do
      let(:user_data) do
        {
          name: "John Doe",
        }
      end

      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { fail!("Invalid bio") }
        end
      end

      it "fails with Axn::Failure" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception).not_to be_a(Axn::ContractViolation::DefaultAssignmentError)
      end

      it "sets the error message" do
        result = action.call(user_data:)
        expect(result.error).to eq("Invalid bio")
      end

      it "triggers on_failure handlers, not on_exception" do
        failure_called = false
        exception_called = false

        action = build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { fail!("Invalid bio") }

          on_failure { failure_called = true }
          on_exception { exception_called = true }
        end

        action.call(user_data:)
        expect(failure_called).to be true
        expect(exception_called).to be false
      end
    end

    context "when done! is called in subfield default block" do
      let(:user_data) do
        {
          name: "John Doe",
        }
      end

      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { done!("Early completion") }
        end
      end

      it "returns a successful result" do
        result = action.call(user_data:)
        expect(result).to be_ok
      end

      it "sets the success message" do
        result = action.call(user_data:)
        expect(result.success).to eq("Early completion")
      end

      it "triggers on_success handlers" do
        success_called = false

        action = build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { done!("Early completion") }

          on_success { success_called = true }
        end

        result = action.call(user_data:)
        expect(result).to be_ok
        expect(success_called).to be true
      end
    end
  end
end
