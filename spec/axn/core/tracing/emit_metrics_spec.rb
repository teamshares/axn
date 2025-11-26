# frozen_string_literal: true

RSpec.describe "Axn::Core::Tracing emit_metrics" do
  let(:metrics_calls) { [] }

  before do
    Axn.configure do |c|
      c.emit_metrics = proc do |resource:, result:|
        metrics_calls << { resource:, result: }
      end
    end
  end

  after do
    Axn.configure do |c|
      c.emit_metrics = nil
    end
  end

  context "when action succeeds" do
    let(:action) { build_axn }

    it "calls emit_metrics with success outcome" do
      result = action.call
      expect(metrics_calls.length).to eq(1)
      expect(metrics_calls.first[:resource]).to eq("AnonymousClass")
      expect(metrics_calls.first[:result]).to eq(result)
      expect(metrics_calls.first[:result].outcome.success?).to be true
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

    it "calls emit_metrics with failure outcome" do
      result = action.call
      expect(metrics_calls.length).to eq(1)
      expect(metrics_calls.first[:resource]).to eq("AnonymousClass")
      expect(metrics_calls.first[:result]).to eq(result)
      expect(metrics_calls.first[:result].outcome.failure?).to be true
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

    it "calls emit_metrics with exception outcome" do
      result = action.call
      expect(metrics_calls.length).to eq(1)
      expect(metrics_calls.first[:resource]).to eq("AnonymousClass")
      expect(metrics_calls.first[:result]).to eq(result)
      expect(metrics_calls.first[:result].outcome.exception?).to be true
    end
  end

  context "when emit_metrics is not configured" do
    before do
      Axn.configure do |c|
        c.emit_metrics = nil
      end
    end

    let(:action) { build_axn }

    it "does not raise an error" do
      expect { action.call }.not_to raise_error
    end
  end

  context "when emit_metrics raises an exception" do
    before do
      Axn.configure do |c|
        c.emit_metrics = proc { |resource:, result:| raise "metrics error" }
      end
    end

    let(:action) { build_axn }

    it "does not interfere with action execution" do
      result = action.call
      expect(result).to be_ok
    end
  end

  context "when emit_metrics only expects resource:" do
    let(:received_args) { [] }

    before do
      Axn.configure do |c|
        c.emit_metrics = proc do |resource:|
          received_args << { resource: }
        end
      end
    end

    after do
      Axn.configure { |c| c.emit_metrics = nil }
    end

    let(:action) { build_axn }

    it "only passes resource: keyword argument" do
      action.call
      expect(received_args.length).to eq(1)
      expect(received_args.first.keys).to eq([:resource])
      expect(received_args.first[:resource]).to eq("AnonymousClass")
    end
  end

  context "when emit_metrics only expects result:" do
    let(:received_args) { [] }

    before do
      Axn.configure do |c|
        c.emit_metrics = proc do |result:|
          received_args << { result: }
        end
      end
    end

    after do
      Axn.configure { |c| c.emit_metrics = nil }
    end

    let(:action) { build_axn }

    it "only passes result: keyword argument" do
      result = action.call
      expect(received_args.length).to eq(1)
      expect(received_args.first.keys).to eq([:result])
      expect(received_args.first[:result]).to eq(result)
    end
  end

  context "when emit_metrics accepts **kwargs" do
    let(:received_args) { [] }

    before do
      Axn.configure do |c|
        c.emit_metrics = proc do |**kwargs|
          received_args << kwargs
        end
      end
    end

    after do
      Axn.configure { |c| c.emit_metrics = nil }
    end

    let(:action) { build_axn }

    it "receives both resource: and result: keyword arguments" do
      result = action.call
      expect(received_args.length).to eq(1)
      expect(received_args.first.keys.sort).to eq(%i[resource result])
      expect(received_args.first[:resource]).to eq("AnonymousClass")
      expect(received_args.first[:result]).to eq(result)
    end
  end
end
