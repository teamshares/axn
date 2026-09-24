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

    # A done! from a callable the contract evaluates is refused: a successful early exit there would skip
    # the validation that guarantees the result's shape. done! belongs in `call` or a hook.
    context "when done! is called in default block" do
      let(:fired) { [] }
      let(:action) do
        fired = self.fired
        build_axn do
          expects :value, default: -> { done!("Early completion") }
          on_success { fired << :on_success }
          define_method(:call) { fired << :call }
        end
      end

      subject(:result) { action.call }

      it "settles as an exception naming the misplaced done!" do
        expect(result.exception).to be_a(Axn::MisplacedFlowControl)
        expect(result.exception.message).to include("resolving the default: for field 'value'")
      end

      it "neither runs call nor fires on_success" do
        result
        expect(fired).to be_empty
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

    # A done! from a callable the contract evaluates is refused: a successful early exit there would skip
    # the validation that guarantees the result's shape. done! belongs in `call` or a hook.
    context "when done! is called in subfield default block" do
      let(:user_data) do
        {
          name: "John Doe",
        }
      end
      let(:fired) { [] }
      let(:action) do
        fired = self.fired
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { done!("Early completion") }
          on_success { fired << :on_success }
          define_method(:call) { fired << :call }
        end
      end

      subject(:result) { action.call(user_data:) }

      it "settles as an exception naming the misplaced done!" do
        expect(result.exception).to be_a(Axn::MisplacedFlowControl)
        expect(result.exception.message).to include("resolving the default: for")
      end

      it "neither runs call nor fires on_success" do
        result
        expect(fired).to be_empty
      end
    end
  end
end
