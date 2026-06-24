# frozen_string_literal: true

# Spike proof: the generic-worker Sidekiq adapter. Confirms the high-risk behaviors that
# the old "action IS the Sidekiq::Job" model provided still hold under the new design.
# Runs against whatever Sidekiq is installed (this dummy app pins v7, os-app's version);
# v8 is covered by a separate standalone check.
RSpec.describe "Sidekiq generic worker (spike)" do
  let(:shared_worker) { Axn::Async::Adapters::Sidekiq::Worker }

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

    let(:subclass) { action.const_get(:AxnSidekiqWorker) }

    it "builds a per-action Worker subclass (a real Sidekiq::Job) carrying the options" do
      expect(subclass.ancestors).to include(shared_worker, Sidekiq::Job)
      expect(subclass.get_sidekiq_options).to include("queue" => "high_priority", "retry" => 5)
    end

    it "enqueues that subclass with action name + kwargs and a display_class for the Web UI" do
      Sidekiq::Testing.fake! do
        jid = action.call_async(name: "Ada")
        expect(jid).to match(/\A[0-9a-f]{24}\z/)

        job = subclass.jobs.last
        expect(job["args"].first).to eq("SpikeQueuedAction")
        expect(job["args"].last).to include("name" => "Ada")
        expect(job["queue"]).to eq("high_priority")
        expect(job["display_class"]).to eq("SpikeQueuedAction")
      end
    end

    it "runs the action when the worker performs the job" do
      Sidekiq::Testing.inline! { expect { action.call_async(name: "Ada") }.not_to raise_error }
    end

    it "keeps the action's own .new private; only the Worker subclass is instantiable" do
      expect { action.new(name: "x") }.to raise_error(NoMethodError, /private method/)
      expect { subclass.new }.not_to raise_error
    end

    it "reconstructs the subclass by name (the fresh-worker autoload path)" do
      # In a worker process Sidekiq constantizes "SpikeQueuedAction::AxnSidekiqWorker", which
      # autoloads the action and re-runs its `async :sidekiq` (same mechanism as ActiveJob's proxy).
      expect(subclass).to eq("SpikeQueuedAction::AxnSidekiqWorker".constantize)
    end
  end

  describe "arbitrary Sidekiq block config (control anything the backend allows)" do
    let(:action) do
      stub_const("SpikeBlockAction", Class.new do
        include Axn
        async :sidekiq, queue: "q1" do
          # Anything a Sidekiq::Job class supports — not just the kwargs we modeled:
          sidekiq_options(tags: ["billing"], dead: false, retry: 7)
          sidekiq_retry_in { |count, _exc| 10 * (count + 1) }
        end
        expects :name
        def call = nil
      end)
    end

    let(:subclass) { action.const_get(:AxnSidekiqWorker) }

    it "applies arbitrary sidekiq_options from the block to the per-action subclass" do
      expect(subclass.get_sidekiq_options).to include(
        "queue" => "q1", "tags" => ["billing"], "dead" => false, "retry" => 7,
      )
    end

    it "supports class-level behavioral hooks from the block (e.g. custom retry backoff)" do
      expect(subclass.sidekiq_retry_in_block.call(2, nil)).to eq(30)
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

    it "uses the dedicated default worker (no per-action subclass to reconstruct in a worker)" do
      Sidekiq::Testing.fake! do
        action.call_async(name: "Grace")
        job = Axn::Async::Adapters::Sidekiq::DefaultWorker.jobs.last
        expect(job["args"].first).to eq("SpikeGlobalDefaultAction")
        expect(job["display_class"]).to eq("SpikeGlobalDefaultAction")
        expect(Axn::Async::Adapters::Sidekiq::DefaultWorker).to be < shared_worker
        expect(action.const_defined?(:AxnSidekiqWorker, false)).to be(false)
      end
    end

    it "executes end-to-end: a fresh worker resolves the action by name and calls it" do
      action # force stub_const
      Sidekiq::Testing.inline! { action.call_async(name: "Grace") }
      expect(SPIKE_SINK).to eq(["Grace"])
    end
  end

  describe "global default block config (applies to the default worker)" do
    around do |ex|
      original = Axn.config._default_async_adapter
      Axn.config.set_default_async(:sidekiq, queue: "kw_queue") { sidekiq_options(retry: 7, dead: false) }
      ex.run
    ensure
      Axn.config.set_default_async(original || false)
    end

    it "carries the default block's options (not just kwargs) onto the default worker" do
      opts = Axn::Async::Adapters::Sidekiq::DefaultWorker.get_sidekiq_options
      expect(opts).to include("queue" => "kw_queue", "retry" => 7, "dead" => false)
    end
  end

  describe "explicit kwargs override block options (precedence preserved)" do
    let(:action) do
      stub_const("SpikePrecedenceAction", Class.new do
        include Axn
        async :sidekiq, queue: "kwarg_wins" do
          sidekiq_options queue: "block_loses"
        end
        expects :name
        def call = nil
      end)
    end

    it "lets the keyword queue win over the block" do
      expect(action.const_get(:AxnSidekiqWorker).get_sidekiq_options["queue"]).to eq("kwarg_wins")
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
      result = shared_worker.new.perform("SpikeDirectAction", serialized)
      expect(result).to be_ok
      expect(result.greeting).to eq("hi Linus")
    end
  end
end
