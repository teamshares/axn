# frozen_string_literal: true

RSpec.describe "Action emit_metrics hook" do
  let(:last_metrics_call) { nil }
  let(:emit_metrics) do
    proc do |resource, result|
      @last_metrics_call = { resource:, result: }
    end
  end

  before do
    Axn.configure do |c|
      c.emit_metrics = emit_metrics
    end
  end

  after do
    Axn.configure do |c|
      c.emit_metrics = nil
    end
  end

  describe "emit_metrics hook execution" do
    context "when action succeeds" do
      let(:action) { build_action }

      it "calls emit_metrics hook with success outcome and correct resource" do
        action.call
        expect(@last_metrics_call[:result].outcome.success?).to be true
        expect(@last_metrics_call[:resource]).to eq("AnonymousClass")
        expect(@last_metrics_call[:result].elapsed_time).to be_a(Float)
        expect(@last_metrics_call[:result].elapsed_time).to be >= 0
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
        expect(@last_metrics_call[:result].outcome.failure?).to be true
      end

      it "calls emit_metrics hook with failure outcome when using call!" do
        expect { action.call! }.to raise_error(Axn::Failure)
        expect(@last_metrics_call[:result].outcome.failure?).to be true
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
        expect(@last_metrics_call[:result].outcome.exception?).to be true
      end

      it "calls emit_metrics hook with exception outcome when using call!" do
        expect { action.call! }.to raise_error(RuntimeError)
        expect(@last_metrics_call[:result].outcome.exception?).to be true
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
        expect(@last_metrics_call[:result].outcome.success?).to be true
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
        expect { action.call! }.to raise_error(Axn::InboundValidationError)
        expect(@last_metrics_call[:result].outcome.exception?).to be true
      end
    end

    context "when no metrics hook is configured" do
      before do
        Axn.configure do |c|
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
