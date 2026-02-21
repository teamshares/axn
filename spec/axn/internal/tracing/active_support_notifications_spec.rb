# frozen_string_literal: true

RSpec.describe "Axn::Internal::Tracing ActiveSupport::Notifications" do
  let(:notifications) { [] }

  before do
    ActiveSupport::Notifications.subscribe("axn.call") do |name, start, finish, id, payload|
      notifications << { name:, start:, finish:, id:, payload: }
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe("axn.call")
  end

  shared_examples "emits notification with outcome" do |outcome|
    it "emits axn.call notification with #{outcome} outcome" do
      result = action.call
      expect(notifications.length).to eq(1)
      expect(notifications.first[:name]).to eq("axn.call")
      expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
      expect(notifications.first[:payload][:outcome]).to eq(outcome)
      expect(notifications.first[:payload][:result]).to eq(result)
      expect(notifications.first[:payload][:elapsed_time]).to be_a(Float)
    end

    it "provides timing information in notification" do
      action.call
      expect(notifications.first[:start]).to be_a(Time)
      expect(notifications.first[:finish]).to be_a(Time)
      expect(notifications.first[:finish]).to be >= notifications.first[:start]
    end

    it "allows access to result via payload action" do
      result = action.call
      expect(notifications.first[:payload][:action]).to be_a(Axn::Core)
      expect(notifications.first[:payload][:action].result).to eq(result)
      expect(notifications.first[:payload][:action].result.outcome.to_s).to eq(outcome)
    end
  end

  context "when action succeeds" do
    let(:action) { build_axn }

    include_examples "emits notification with outcome", "success"

    it "does not include exception in payload" do
      action.call
      expect(notifications.first[:payload][:exception]).to be_nil
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

    include_examples "emits notification with outcome", "failure"

    it "includes exception in payload" do
      result = action.call
      expect(notifications.first[:payload][:exception]).to be_a(Axn::Failure)
      expect(notifications.first[:payload][:exception]).to eq(result.exception)
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

    include_examples "emits notification with outcome", "exception"

    it "includes exception in payload" do
      result = action.call
      expect(notifications.first[:payload][:exception]).to be_a(RuntimeError)
      expect(notifications.first[:payload][:exception]).to eq(result.exception)
    end
  end

  context "with named action class" do
    let(:action) do
      build_axn do
        def self.name
          "TestAction"
        end
      end
    end

    it "uses class name as resource in notification" do
      action.call
      expect(notifications.first[:payload][:resource]).to eq("TestAction")
    end
  end

  context "when OpenTelemetry is not available" do
    before do
      # Temporarily hide OpenTelemetry if it exists
      @original_otel = defined?(OpenTelemetry) ? OpenTelemetry : nil
      Object.send(:remove_const, :OpenTelemetry) if @original_otel
    end

    after do
      # Restore OpenTelemetry if it was defined
      Object.const_set(:OpenTelemetry, @original_otel) if @original_otel && !defined?(OpenTelemetry)
    end

    let(:action) { build_axn }

    it "still emits ActiveSupport::Notifications" do
      action.call
      expect(notifications.length).to eq(1)
      expect(notifications.first[:name]).to eq("axn.call")
    end
  end
end
