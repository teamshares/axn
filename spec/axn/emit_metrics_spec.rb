# frozen_string_literal: true

RSpec.describe "Action axn.call notification metrics" do
  let(:notifications) { [] }

  before do
    ActiveSupport::Notifications.subscribe("axn.call") do |name, start, finish, id, payload|
      notifications << { name:, start:, finish:, id:, payload: }
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe("axn.call")
  end

  describe "axn.call notification emission for metrics" do
    context "when action succeeds" do
      let(:action) { build_axn }

      it "emits notification with success outcome and correct resource" do
        result = action.call
        expect(notifications.length).to eq(1)
        expect(notifications.first[:payload][:action].result.outcome.success?).to be true
        expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
        expect(notifications.first[:payload][:action].result.elapsed_time).to be_a(Float)
        expect(notifications.first[:payload][:action].result.elapsed_time).to be >= 0
        expect(notifications.first[:payload][:action].result).to eq(result)
      end
    end

    context "when action fails with fail!" do
      let(:action) do
        build_axn do
          def call
            fail! "intentional failure"
          end
        end
      end

      it "emits notification with failure outcome" do
        action.call
        expect(notifications.first[:payload][:action].result.outcome.failure?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("failure")
      end

      it "emits notification with failure outcome when using call!" do
        expect { action.call! }.to raise_error(Axn::Failure)
        expect(notifications.first[:payload][:action].result.outcome.failure?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("failure")
      end
    end

    context "when action raises an exception" do
      let(:action) do
        build_axn do
          def call
            raise "intentional exception"
          end
        end
      end

      it "emits notification with exception outcome" do
        action.call
        expect(notifications.first[:payload][:action].result.outcome.exception?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("exception")
      end

      it "emits notification with exception outcome when using call!" do
        expect { action.call! }.to raise_error(RuntimeError)
        expect(notifications.first[:payload][:action].result.outcome.exception?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("exception")
      end
    end

    context "when call! succeeds" do
      let(:action) do
        build_axn do
          expects :required_field
          exposes :value
          def call
            expose :value, 42
          end
        end
      end

      it "emits notification with success outcome" do
        result = action.call!(required_field: "test")
        expect(result).to be_ok
        expect(notifications.first[:payload][:action].result.outcome.success?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("success")
      end
    end

    context "when call! raises an exception" do
      let(:action) do
        build_axn do
          expects :required_field
          exposes :value
          def call
            expose :value, 42
          end
        end
      end

      it "emits notification with exception outcome" do
        expect { action.call! }.to raise_error(Axn::InboundValidationError)
        expect(notifications.first[:payload][:action].result.outcome.exception?).to be true
        expect(notifications.first[:payload][:action].result.outcome.to_s).to eq("exception")
      end
    end
  end
end
