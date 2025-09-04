# frozen_string_literal: true

RSpec.describe "Action wrap_with_trace hook" do
  let(:last_trace_call) { nil }
  let(:wrap_with_trace) do
    proc do |resource, &action|
      @last_trace_call = { resource:, action_called: false }
      action.call
      @last_trace_call[:action_called] = true
    end
  end

  before do
    Axn.configure do |c|
      c.wrap_with_trace = wrap_with_trace
    end
  end

  after do
    Axn.configure do |c|
      c.wrap_with_trace = nil
    end
  end

  describe "wrap_with_trace hook execution" do
    context "when action succeeds" do
      let(:action) { build_action }

      it "calls wrap_with_trace hook with correct resource and executes action" do
        action.call
        expect(@last_trace_call[:resource]).to eq("AnonymousClass")
        expect(@last_trace_call[:action_called]).to eq(true)
      end
    end

    context "when action fails with fail!" do
      let(:action) do
        build_action do
          def call
            fail! "intentional failure"
          end
        end
      end

      it "calls wrap_with_trace hook and executes action" do
        result = action.call
        expect(result).not_to be_ok
        expect(@last_trace_call[:action_called]).to eq(true)
      end

      it "calls wrap_with_trace hook and executes action when using call!" do
        expect { action.call! }.to raise_error(Axn::Failure)
        expect(@last_trace_call[:action_called]).to eq(true)
      end
    end

    context "when action raises an exception" do
      let(:action) do
        build_action do
          def call
            raise "intentional exception"
          end
        end
      end

      it "calls wrap_with_trace hook and executes action" do
        result = action.call
        expect(result).not_to be_ok
        expect(@last_trace_call[:action_called]).to eq(true)
      end

      it "calls wrap_with_trace hook and executes action when using call!" do
        expect { action.call! }.to raise_error(RuntimeError)
        expect(@last_trace_call[:action_called]).to eq(true)
      end
    end

    context "when call! succeeds" do
      let(:action) do
        build_action do
          expects :required_field
          exposes :value
          def call
            expose :value, 42
          end
        end
      end

      it "calls wrap_with_trace hook and executes action" do
        result = action.call!(required_field: "test")
        expect(result).to be_ok
        expect(@last_trace_call[:action_called]).to eq(true)
      end
    end

    context "when call! raises an exception" do
      let(:action) do
        build_action do
          expects :required_field
          exposes :value
          def call
            expose :value, 42
          end
        end
      end

      it "calls wrap_with_trace hook and executes action" do
        expect { action.call! }.to raise_error(Axn::InboundValidationError)
        expect(@last_trace_call[:action_called]).to eq(true)
      end
    end

    context "when no wrap_with_trace hook is configured" do
      before do
        Axn.configure do |c|
          c.wrap_with_trace = nil
        end
      end

      it "does not call wrap_with_trace hook" do
        action = build_action
        action.call
        expect(@last_trace_call).to be_nil
      end
    end

    context "when wrap_with_trace hook raises an exception" do
      let(:wrap_with_trace) do
        proc do |_resource, &_action|
          raise "trace hook error"
        end
      end

      let(:action) { build_action }

      before do
        allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
      end

      it "calls Axn::Internal::Logging.piping_error when wrap_with_trace hook raises" do
        action.call
        expect(Axn::Internal::Logging).to have_received(:piping_error).with(
          "running trace hook",
          hash_including(
            action:,
            exception: an_object_satisfying { |e| e.is_a?(RuntimeError) && e.message == "trace hook error" },
          ),
        )
      end

      it "still executes the action despite trace hook error" do
        result = action.call
        expect(result).to be_ok
      end
    end

    context "when wrap_with_trace hook does not call the action block" do
      let(:wrap_with_trace) do
        proc do |resource, &_action|
          @last_trace_call = { resource:, action_called: false }
          # Intentionally not calling action.call
        end
      end

      let(:action) do
        build_action do
          def call
            @called = true
          end
        end
      end

      it "does not execute the action" do
        action.call
        expect(@last_trace_call[:action_called]).to eq(false)
        expect(action.instance_variable_get(:@called)).to be_nil
      end
    end

    context "with named action class" do
      let(:action) do
        build_action do
          def self.name
            "TestAction"
          end
        end
      end

      it "passes the correct class name to wrap_with_trace" do
        action.call
        expect(@last_trace_call[:resource]).to eq("TestAction")
      end
    end

    context "with anonymous class" do
      let(:action) { build_action }

      it "passes AnonymousClass as resource name" do
        action.call
        expect(@last_trace_call[:resource]).to eq("AnonymousClass")
      end
    end
  end
end
