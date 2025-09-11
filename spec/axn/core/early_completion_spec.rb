# frozen_string_literal: true

RSpec.describe Axn do
  describe "#done!" do
    subject { action.call }

    context "when done! is called with a message" do
      let(:action) do
        build_axn do
          def call
            done!("Early completion message")
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "sets the success message" do
        expect(subject.success).to eq("Early completion message")
      end

      it "does not execute after hooks and triggers on_success callbacks" do
        after_called = false
        success_called = false
        action = build_axn do
          after { after_called = true }
          on_success { success_called = true }

          def call
            done!("Early completion")
          end
        end

        action.call
        expect(after_called).to be false
        expect(success_called).to be true
      end

      it "does not trigger rollback when used with transaction strategy" do
        # This will be tested with a mock transaction that tracks rollbacks
        rollback_called = false

        # Mock ActiveRecord transaction behavior
        stub_const("ActiveRecord::Base", Class.new)
        allow(ActiveRecord::Base).to receive(:transaction).and_yield
        allow(ActiveRecord::Base).to receive(:rollback!) { rollback_called = true }

        action = build_axn do
          use :transaction

          def call
            done!("Early completion")
          end
        end

        action.call
        expect(rollback_called).to be false
      end
    end

    context "when done! is called without a message" do
      let(:action) do
        build_axn do
          success "Default success message"

          def call
            done!
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "uses the default success message" do
        expect(subject.success).to eq("Default success message")
      end
    end

    context "when done! is called with nil message" do
      let(:action) do
        build_axn do
          success "Default success message"

          def call
            done!(nil)
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "uses the default success message" do
        expect(subject.success).to eq("Default success message")
      end
    end

    context "when done! is called in a before hook" do
      let(:action) do
        build_axn do
          before { done!("Early completion in before hook") }

          def call
            # This should not be executed
            raise "This should not be called"
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "does not execute the call method" do
        expect { subject }.not_to raise_error
      end

      it "does not execute after hooks" do
        after_called = false
        action = build_axn do
          before { done!("Early completion") }
          after { after_called = true }

          def call
            # This should not be executed
          end
        end

        action.call
        expect(after_called).to be false
      end
    end

    context "when done! is called in an around hook" do
      let(:action) do
        build_axn do
          around do |block|
            done!("Early completion in around hook")
            block.call # This should not be executed
          end

          def call
            raise "This should not be called"
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "does not execute the call method" do
        expect { subject }.not_to raise_error
      end
    end

    context "when done! is called in an after hook" do
      let(:action) do
        build_axn do
          after { done!("Early completion in after hook") }

          def call
            # This should execute normally
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "executes the call method" do
        expect { subject }.not_to raise_error
      end

      it "executes the after hook that calls done! but skips subsequent after hooks" do
        first_after_called = false
        second_after_called = false
        success_called = false
        action = build_axn do
          after do
            first_after_called = true
            done!("Early completion in after hook")
          end
          after { second_after_called = true }
          on_success { success_called = true }

          def call
            # This should execute normally
          end
        end

        action.call
        expect(first_after_called).to be true
        expect(second_after_called).to be false
        expect(success_called).to be true
      end
    end

    context "when done! is called without providing required exposes" do
      let(:action) do
        build_axn do
          exposes :required_field

          def call
            done!("Early completion without exposes")
          end
        end
      end

      it "fails due to outbound validation even with early completion" do
        result = action.call
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::OutboundValidationError)
        expect(result.exception.message).to include("Required field can't be blank")
      end
    end

    context "when done! is called with exposures" do
      let(:action) do
        build_axn do
          exposes :user_id, :status

          def call
            done!("User processed", user_id: 123, status: "Success")
          end
        end
      end

      it "exposes the provided data and returns success" do
        result = action.call
        expect(result).to be_ok
        expect(result.user_id).to eq(123)
        expect(result.status).to eq("Success")
        expect(result.success).to eq("User processed")
      end
    end

    context "when done! is called with only exposures (no message)" do
      let(:action) do
        build_axn do
          exposes :status, :count

          def call
            done!(status: "completed", count: 42)
          end
        end
      end

      it "exposes the provided data and uses default success message" do
        result = action.call
        expect(result).to be_ok
        expect(result.status).to eq("completed")
        expect(result.count).to eq(42)
        expect(result.success).to eq("Action completed successfully")
      end
    end

    context "when fail! is called with exposures" do
      let(:action) do
        build_axn do
          exposes :error_code, :details

          def call
            fail!("Validation failed", error_code: 422, details: "Invalid input")
          end
        end
      end

      it "exposes the provided data and returns failure" do
        result = action.call
        expect(result).not_to be_ok
        expect(result.error_code).to eq(422)
        expect(result.details).to eq("Invalid input")
        expect(result.error).to eq("Validation failed")
      end
    end

    context "when fail! is called with only exposures (no message)" do
      let(:action) do
        build_axn do
          exposes :status, :reason

          def call
            fail!(status: "error", reason: "Database connection failed")
          end
        end
      end

      it "exposes the provided data and uses default error message" do
        result = action.call
        expect(result).not_to be_ok
        expect(result.status).to eq("error")
        expect(result.reason).to eq("Database connection failed")
        expect(result.error).to eq("Something went wrong")
      end
    end

    context "when done! is called after some work in call method" do
      let(:work_done) { [] }
      let(:action) do
        work_done_ref = work_done
        build_axn do
          define_method :call do
            work_done_ref << "work_started"
            done!("Work completed early")
            work_done_ref << "work_after_done" # This should not be executed
          end
        end
      end

      it "returns a successful result" do
        is_expected.to be_ok
      end

      it "stops execution after done! call" do
        subject
        expect(work_done).to eq(["work_started"])
      end
    end

    context "with multiple on_success callbacks" do
      let(:callbacks_called) { [] }
      let(:action) do
        callbacks_ref = callbacks_called
        build_axn do
          on_success { callbacks_ref << "first_success" }
          on_success { callbacks_ref << "second_success" }
          on_success { callbacks_ref << "third_success" }

          def call
            done!("Early completion")
          end
        end
      end

      it "calls all on_success callbacks" do
        subject
        expect(callbacks_called).to eq(%w[third_success second_success first_success])
      end
    end

    context "when on_success callback fails" do
      let(:action) do
        build_axn do
          on_success { raise "Success callback failed" }
          on_success { "This should still run" }

          def call
            done!("Early completion")
          end
        end
      end

      it "continues running other on_success callbacks" do
        # This should not raise an error and should still be successful
        expect { subject }.not_to raise_error
        is_expected.to be_ok
      end
    end

    context "when done! is called in a nested action" do
      let(:parent_action) do
        build_axn do
          expects :child_action
          exposes :child_result

          def call
            child_result = child_action.call
            expose :child_result, child_result
          end
        end
      end

      let(:child_action) do
        build_axn do
          def call
            done!("Child early completion")
          end
        end
      end

      it "allows nested actions to use done!" do
        result = parent_action.call(child_action:)
        expect(result).to be_ok
        expect(result.child_result).to be_ok
        expect(result.child_result.success).to eq("Child early completion")
      end
    end

    context "error handling" do
      it "raises Axn::Internal::EarlyCompletion when called" do
        action = build_axn do
          def call
            done!("test message")
          end
        end

        # This should be caught internally, but we can test the exception is raised
        expect { action.new.done!("test") }.to raise_error(Axn::Internal::EarlyCompletion, "test")
      end

      it "raises Axn::Internal::EarlyCompletion with nil message" do
        action = build_axn do
          def call
            done!(nil)
          end
        end

        expect { action.new.done!(nil) }.to raise_error(Axn::Internal::EarlyCompletion, nil)
      end
    end
  end
end
