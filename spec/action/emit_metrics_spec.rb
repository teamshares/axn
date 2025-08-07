# frozen_string_literal: true

RSpec.describe "Action emit_metrics hook" do
  let(:last_metrics_call) { nil }
  let(:emit_metrics) do
    proc do |resource, outcome|
      @last_metrics_call = { resource:, outcome: }
    end
  end

  before do
    Action.configure do |c|
      c.emit_metrics = emit_metrics
    end
  end

  after do
    Action.configure do |c|
      c.emit_metrics = nil
    end
  end

  describe "emit_metrics hook execution" do
    context "when action succeeds" do
      let(:action) { build_action }

      it "calls emit_metrics hook with success outcome and correct resource" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("success")
        expect(@last_metrics_call[:resource]).to eq("AnonymousClass")
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

      it "calls emit_metrics hook with failure outcome" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("failure")
      end

      it "calls emit_metrics hook with failure outcome when using call!" do
        expect { action.call! }.to raise_error(Action::Failure)
        expect(@last_metrics_call[:outcome]).to eq("failure")
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

      it "calls emit_metrics hook with exception outcome" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("exception")
      end

      it "calls emit_metrics hook with exception outcome when using call!" do
        expect { action.call! }.to raise_error(RuntimeError)
        expect(@last_metrics_call[:outcome]).to eq("exception")
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

      it "calls emit_metrics hook with success outcome" do
        result = action.call!(required_field: "test")
        expect(result).to be_ok
        expect(@last_metrics_call[:outcome]).to eq("success")
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

      it "calls emit_metrics hook with exception outcome" do
        expect { action.call! }.to raise_error(Action::InboundValidationError)
        expect(@last_metrics_call[:outcome]).to eq("exception")
      end
    end

    context "when no metrics hook is configured" do
      before do
        Action.configure do |c|
          c.emit_metrics = nil
        end
      end

      it "does not call emit_metrics hook" do
        action = build_action
        action.call
        expect(@last_metrics_call).to be_nil
      end
    end
  end
end
