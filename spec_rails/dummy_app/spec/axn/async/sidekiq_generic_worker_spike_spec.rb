# frozen_string_literal: true

# Spike proof: the generic-worker Sidekiq adapter. Confirms the high-risk behaviors that
# the old "action IS the Sidekiq::Job" model provided still hold under the new design.
RSpec.describe "Sidekiq generic worker (spike)" do
  let(:worker) { Axn::Async::Adapters::Sidekiq::Worker }

  before { Sidekiq::Job.jobs.clear }
  after { Sidekiq::Job.jobs.clear }

  describe "explicit async :sidekiq with per-action options" do
    let(:action) do
      stub_const("SpikeQueuedAction", Class.new do
        include Axn
        async :sidekiq, queue: "high_priority", retry: 5
        expects :name
        exposes :greeting
        def call = expose(greeting: "hi #{name}")
      end)
    end

    it "enqueues the generic Worker (not the action) with action name + kwargs, queue/retry, and display_class" do
      Sidekiq::Testing.fake! do
        jid = action.call_async(name: "Ada")
        expect(jid).to match(/\A[0-9a-f]{24}\z/)

        jobs = worker.jobs
        expect(jobs.size).to eq(1)
        job = jobs.first
        expect(job["class"]).to eq("Axn::Async::Adapters::Sidekiq::Worker")
        expect(job["args"].first).to eq("SpikeQueuedAction")             # action resolved by name
        expect(job["args"].last).to include("name" => "Ada")             # serialized kwargs
        expect(job["queue"]).to eq("high_priority")                      # per-action queue preserved
        expect(job["retry"]).to eq(5)                                    # per-action retry preserved
        expect(job["display_class"]).to eq("SpikeQueuedAction")          # Sidekiq Web UI shows the real action
      end
    end

    it "runs the action when the worker performs the job" do
      Sidekiq::Testing.inline! do
        expect { action.call_async(name: "Ada") }.not_to raise_error
      end
    end

    it "keeps the action's own .new private (only the generic Worker is instantiated by Sidekiq)" do
      expect { action.new(name: "x") }.to raise_error(NoMethodError, /private method/)
      expect { worker.new }.not_to raise_error
    end
  end

  describe "relying on the global default adapter (the path that broke with private new)" do
    around do |ex|
      original = Axn.config._default_async_adapter
      Axn.config.set_default_async(:sidekiq)
      ex.run
    ensure
      Axn.config.set_default_async(original || false)
    end

    before { stub_const("SPIKE_SINK", []) }

    let(:action) do
      stub_const("SpikeGlobalDefaultAction", Class.new do
        include Axn
        # NOTE: no `async` declaration — relies entirely on the global default
        expects :name
        def call = SPIKE_SINK << name
      end)
    end

    it "enqueues via the generic Worker without the action ever being a Sidekiq::Job" do
      Sidekiq::Testing.fake! do
        jid = action.call_async(name: "Grace")
        expect(jid).to match(/\A[0-9a-f]{24}\z/)
        expect(worker.jobs.last["args"].first).to eq("SpikeGlobalDefaultAction")
      end
    end

    it "executes end-to-end: a fresh worker resolves the action by name and calls it" do
      action # force stub_const
      Sidekiq::Testing.inline! { action.call_async(name: "Grace") }
      expect(SPIKE_SINK).to eq(["Grace"])
    end
  end

  describe "Worker dispatch directly (simulating Sidekiq::Processor#dispatch)" do
    it "constantizes the action by name and calls it with deserialized kwargs" do
      stub_const("SpikeDirectAction", Class.new do
        include Axn
        expects :name
        exposes :greeting
        def call = expose(greeting: "hi #{name}")
      end)

      serialized = Axn::Internal::AsyncSerialization.serialize(name: "Linus")
      result = worker.new.perform("SpikeDirectAction", serialized)
      expect(result).to be_ok
      expect(result.greeting).to eq("hi Linus")
    end
  end
end
