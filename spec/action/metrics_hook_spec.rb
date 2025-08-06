# frozen_string_literal: true

RSpec.describe "Action metrics hook" do
  let(:last_metrics_call) { nil }
  let(:metrics_hook) do
    proc do |resource, outcome|
      @last_metrics_call = { resource:, outcome: }
    end
  end

  before do
    Action.configure do |c|
      c.metrics_hook = metrics_hook
    end
  end

  after do
    Action.configure do |c|
      c.metrics_hook = nil
    end
  end

  describe "metrics hook execution" do
    context "when action succeeds" do
      let(:action) do
        Class.new do
          include Action
          def call; end
        end
      end

      it "calls metrics hook with success outcome and correct resource" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("success")
        expect(@last_metrics_call[:resource]).to eq("AnonymousClass")
      end
    end

    context "when action fails with fail!" do
      let(:action) do
        Class.new do
          include Action
          def call
            fail! "intentional failure"
          end
        end
      end

      it "calls metrics hook with failure outcome" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("failure")
      end
    end

    context "when action raises an exception" do
      let(:action) do
        Class.new do
          include Action
          def call
            raise "intentional exception"
          end
        end
      end

      it "calls metrics hook with exception outcome" do
        action.call
        expect(@last_metrics_call[:outcome]).to eq("exception")
      end
    end

    context "when call! raises an exception" do
      let(:action) do
        Class.new do
          include Action
          expects :required_field
          def call
            expose :value, 42
          end
        end
      end

      it "calls metrics hook with exception outcome" do
        expect { action.call! }.to raise_error(Action::InboundValidationError)
        expect(@last_metrics_call[:outcome]).to eq("exception")
      end
    end

    context "when no metrics hook is configured" do
      before do
        Action.configure do |c|
          c.metrics_hook = nil
        end
      end

      it "does not call metrics hook" do
        action = Class.new do
          include Action
          def call; end
        end

        action.call
        expect(@last_metrics_call).to be_nil
      end
    end
  end
end
