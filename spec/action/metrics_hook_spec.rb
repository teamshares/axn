# frozen_string_literal: true

RSpec.describe "Action metrics hook" do
  let(:metrics_called) { [] }
  let(:metrics_hook) do
    proc do |resource, result|
      metrics_called << {
        resource:,
        outcome: determine_outcome(result),
      }
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

  def determine_outcome(result)
    return "exception" if result.exception
    return "failure" if result.failure?

    "success"
  end

  describe "metrics hook execution" do
    context "when action succeeds" do
      let(:action) do
        Class.new do
          include Action

          def call
            # Simple action that just succeeds
          end
        end
      end

      it "calls metrics hook with success outcome" do
        action.call

        expect(metrics_called.length).to eq(1)
        expect(metrics_called.first[:outcome]).to eq("success")
        expect(metrics_called.first[:resource]).to eq("AnonymousClass")
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

        expect(metrics_called.length).to eq(1)
        expect(metrics_called.first[:outcome]).to eq("failure")
        expect(metrics_called.first[:resource]).to eq("AnonymousClass")
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

        expect(metrics_called.length).to eq(1)
        expect(metrics_called.first[:outcome]).to eq("exception")
        expect(metrics_called.first[:resource]).to eq("AnonymousClass")
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

      it "calls metrics hook with the correct outcome" do
        expect { action.call! }.to raise_error(Action::InboundValidationError)

        expect(metrics_called.length).to eq(1)
        expect(metrics_called.first[:outcome]).to eq("exception")
        expect(metrics_called.first[:resource]).to eq("AnonymousClass")
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

        expect(metrics_called).to be_empty
      end
    end
  end
end
