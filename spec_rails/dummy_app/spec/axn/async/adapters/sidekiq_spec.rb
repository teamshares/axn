# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_rails_behavior"

RSpec.describe "Axn::Async with Sidekiq adapter", :sidekiq do
  let(:test_action) { Actions::Async::TestActionSidekiq }
  let(:failing_action) { Actions::Async::FailingActionSidekiq }
  let(:expected_log_message) { /Action executed: Hello, World! You are 25 years old\./ }

  # Shared example configuration
  let(:enqueue_job) { ->(action, args) { action.call_async(**args) } }
  let(:perform_enqueued) { -> {} } # Sidekiq inline mode executes immediately
  let(:action_with_only_exhausted) { Actions::Async::Sidekiq::OnlyExhausted }
  let(:action_with_every_attempt) { Actions::Async::Sidekiq::EveryAttempt }

  before do
    Sidekiq::Testing.inline!
    Sidekiq.strict_args!(false)
    allow(Axn.config.logger).to receive(:info).and_call_original
    Sidekiq::Job.clear_all
  end

  after do
    Sidekiq::Testing.fake!
    Sidekiq.strict_args!(true)
    Sidekiq::Job.clear_all
  end

  it_behaves_like "async adapter rails delayed execution"
  it_behaves_like "async adapter rails per-class exception reporting"

  describe ".call_async" do
    it { expect(test_action.call_async(name: "World", age: 25)).to match(/\A[0-9a-f]{24}\z/) }
    it { expect(test_action.call_async(name: "World", age: 25, active: true, tags: ["test"])).to match(/\A[0-9a-f]{24}\z/) }
  end

  describe "GlobalID integration" do
    let(:user) { User.create!(name: "Test User") }
    let(:global_id_action) { Actions::Async::TestActionSidekiqGlobalId }

    after { User.delete_all }

    it { expect(global_id_action.call_async(name: "World", user:)).to match(/\A[0-9a-f]{24}\z/) }

    it "converts GlobalID objects during enqueue serialization" do
      Sidekiq::Testing.fake!
      Sidekiq::Job.clear_all

      expect(global_id_action.call_async(name: "World", user:)).to match(/\A[0-9a-f]{24}\z/)

      # args == [action_class_name, serialized_kwargs]; the kwargs carry the GlobalID
      job_kwargs = Sidekiq::Job.jobs.last["args"].last
      expect(job_kwargs).to include(
        "name" => "World",
        "user" => hash_including("_aj_globalid" => a_string_matching(%r{\Agid://[^/]+/User/\d+\z})),
      )
    end
  end

  describe "Sidekiq options configuration" do
    # Per-action sidekiq options now live on the generated per-action Worker subclass
    # (the action itself is no longer a Sidekiq::Job).
    it "applies sidekiq_options from async config" do
      expect(Actions::Async::TestActionSidekiqWithOptions::AxnSidekiqWorker.get_sidekiq_options).to include(
        "queue" => "high_priority",
        "retry" => 3,
      )
      expect(Actions::Async::TestActionSidekiqWithOptions.call_async(name: "Test", age: 25)).to match(/\A[0-9a-f]{24}\z/)
    end

    it { expect(test_action::AxnSidekiqWorker.get_sidekiq_options).to be_a(Hash) }
  end

  describe "Sidekiq job execution" do
    it { expect { test_action.call_async(name: "World", age: 25) }.not_to raise_error }
    it { expect { Actions::Async::TestActionSidekiqNoArgs.call_async }.not_to raise_error }
    it { expect { test_action.call_async(name: "Rails", age: 30, active: true, tags: ["test"]) }.not_to raise_error }
    it {
      expect do
        test_action.call_async(name: "World", age: 25)
        test_action.call_async(name: "Rails", age: 30)
      end.not_to raise_error
    }

    it "logs action execution details" do
      test_action.call_async(name: "World", age: 25)
      expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
    end

    it "logs before failing" do
      expect { failing_action.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")
      expect(Axn.config.logger).to have_received(:info).with(/About to fail with name: Test/)
    end
  end

  describe "Sidekiq testing modes" do
    context "when Sidekiq::Testing.inline! is enabled" do
      before { Sidekiq::Testing.inline! }

      it "executes call_async immediately and synchronously" do
        executed = false
        allow_any_instance_of(test_action).to receive(:call) {
          executed = true
          "Hello, World!"
        }

        expect(test_action.call_async(name: "World", age: 25)).to match(/\A[0-9a-f]{24}\z/)
        expect(executed).to be true
      end

      it "logs action execution immediately" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
      end
    end

    context "when Sidekiq::Testing.fake! is enabled" do
      before do
        Sidekiq::Testing.fake!
        Sidekiq::Job.clear_all
      end

      after do
        Sidekiq::Testing.inline!
        Sidekiq::Job.clear_all
      end

      it "enqueues job in Sidekiq jobs array" do
        Sidekiq::Job.clear_all
        expect { test_action.call_async(name: "World", age: 25) }.to change { Sidekiq::Job.jobs.size }.by(1)
      end

      it "enqueues call_async without executing immediately" do
        executed = false
        allow_any_instance_of(test_action).to receive(:call) {
          executed = true
          "Hello, World!"
        }

        expect(test_action.call_async(name: "World", age: 25)).to match(/\A[0-9a-f]{24}\z/)
        expect(executed).to be false
      end

      it "does not log action execution immediately when fake" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).not_to have_received(:info).with(expected_log_message)
      end

      it "can execute enqueued jobs manually" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).not_to have_received(:info).with(expected_log_message)

        job_data = Sidekiq::Job.jobs.first
        job_data["class"].constantize.send(:new).perform(*job_data["args"])

        expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
      end
    end
  end

  describe "Sidekiq error handling" do
    it { expect { failing_action.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure") }

    context "with unserializable objects" do
      let(:unserializable_object) do
        obj = Object.new
        obj.define_singleton_method(:to_s) { raise "Cannot serialize" }
        obj
      end

      before do
        expect { JSON.generate(unserializable_object) }.to raise_error(RuntimeError, "Cannot serialize")
        Sidekiq.strict_args!(true)
      end

      after { Sidekiq.strict_args!(false) }

      it { expect { test_action.call_async(name: "Test", age: 25, unserializable: unserializable_object) }.to raise_error(Axn::Async::UnserializableArgument) }
      it { expect { test_action.call_async(name: "Test", age: 25, complex: unserializable_object) }.to raise_error(Axn::Async::UnserializableArgument) }
    end
  end

  describe "_async config with symbol keys and durations" do
    context "with symbol keys" do
      it "accepts _async config with symbol keys for wait" do
        expect { test_action.call_async(name: "World", age: 25, _async: { wait: 3600 }) }.not_to raise_error
      end

      it "accepts _async config with symbol keys for wait_until" do
        future_time = 1.hour.from_now
        expect { test_action.call_async(name: "World", age: 25, _async: { wait_until: future_time }) }.not_to raise_error
      end

      it "does not leak _async into job arguments" do
        Sidekiq::Testing.fake!
        Sidekiq::Job.clear_all

        test_action.call_async(name: "World", age: 25, _async: { wait: 3600 })

        job = Sidekiq::Job.jobs.first
        expect(job["args"].last).not_to have_key("_async")
        expect(job["args"].last).not_to have_key(:_async)
      end
    end

    context "with ActiveSupport::Duration values" do
      it "accepts duration for wait option" do
        expect { test_action.call_async(name: "World", age: 25, _async: { wait: 5.minutes }) }.not_to raise_error
      end

      it "accepts duration for wait option with symbol key" do
        expect { test_action.call_async(name: "World", age: 25, _async: { wait: 1.hour }) }.not_to raise_error
      end

      it "does not leak _async into job arguments with duration" do
        Sidekiq::Testing.fake!
        Sidekiq::Job.clear_all

        test_action.call_async(name: "World", age: 25, _async: { wait: 5.minutes })

        job = Sidekiq::Job.jobs.first
        expect(job["args"].last).not_to have_key("_async")
        expect(job["args"].last).not_to have_key(:_async)
      end

      it "converts duration to seconds correctly" do
        Sidekiq::Testing.fake!
        Sidekiq::Job.clear_all

        test_action.call_async(name: "World", age: 25, _async: { wait: 5.minutes })

        # 5.minutes is normalized to 300s and scheduled via perform_in on the Worker
        job = Sidekiq::Job.jobs.first
        expect((job["at"] - job["created_at"]).round).to eq(300) # 5.minutes = 300 seconds
      end
    end

    context "with both symbol keys and durations" do
      it "handles symbol keys with duration values" do
        expect { test_action.call_async(name: "World", age: 25, _async: { wait: 30.minutes }) }.not_to raise_error
      end

      it "does not cause serialization errors" do
        Sidekiq::Testing.fake!
        Sidekiq::Job.clear_all
        Sidekiq.strict_args!(true)

        expect { test_action.call_async(name: "World", age: 25, _async: { wait: 5.minutes }) }.not_to raise_error

        Sidekiq.strict_args!(false)
      end
    end
  end

  # Migrated from the deleted non-rails mock-based spec/axn/async/adapters/sidekiq_spec.rb
  # ("async adapter exception handling" + "per-class async_exception_reporting override"
  # shared examples). The old model performed the action directly (it WAS the Sidekiq::Job);
  # here we dispatch through the real generic Worker: Worker#perform(action_name, kwargs).
  describe "Worker dispatch exception handling" do
    def dispatch(action, kwargs = {})
      action.const_get(:AxnSidekiqWorker).new.perform(action.name, Axn::Internal::AsyncSerialization.serialize(kwargs))
    end

    let(:success_action) do
      stub_const("WorkerDispatchSuccess", Class.new do
        include Axn
        async :sidekiq
        expects :value
        exposes :result_value
        def call = expose(result_value: value * 2)
      end)
    end

    let(:fail_action) do
      stub_const("WorkerDispatchFail", Class.new do
        include Axn
        async :sidekiq
        expects :should_fail
        def call = (fail!("Business logic failure") if should_fail)
      end)
    end

    let(:exception_action) do
      stub_const("WorkerDispatchRaise", Class.new do
        include Axn
        async :sidekiq
        def call = raise("Unexpected error")
      end)
    end

    it "returns result on success" do
      result = dispatch(success_action, value: 5)
      expect(result).to be_ok
      expect(result.result_value).to eq(10)
    end

    it "does not raise on Axn::Failure (business logic failure)" do
      expect { dispatch(fail_action, should_fail: true) }.not_to raise_error

      result = dispatch(fail_action, should_fail: true)
      expect(result.outcome).to be_failure
      expect(result.exception).to be_a(Axn::Failure)
    end

    it "re-raises unexpected exceptions for retry" do
      expect { dispatch(exception_action) }.to raise_error(RuntimeError, "Unexpected error")
    end
  end

  # Migrated from the deleted non-rails "per-class async_exception_reporting override" shared
  # example. Per-attempt reporting routes through the executor, which reads the action's
  # _async_exception_reporting and the CurrentRetryContext set by the Sidekiq middleware.
  describe "per-class async_exception_reporting override (via Worker dispatch)" do
    let(:retry_context) do
      Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
    end

    around do |example|
      Axn::Async::CurrentRetryContext.with(retry_context) { example.run }
    end

    def dispatch_and_capture(action)
      on_exception_called = false
      original = Axn.config.method(:on_exception)
      allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
        on_exception_called = true
        original.call(*args, **kwargs)
      end
      expect { action.const_get(:AxnSidekiqWorker).new.perform(action.name, {}) }.to raise_error(RuntimeError)
      on_exception_called
    end

    it "does not trigger on_exception on intermediate attempts when per-class is :only_exhausted" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)
      action = stub_const("WorkerDispatchOnlyExhausted", Class.new do
        include Axn
        async :sidekiq
        async_exception_reporting :only_exhausted
        def call = raise("Test error")
      end)
      expect(dispatch_and_capture(action)).to be false
    end

    it "triggers on_exception on every attempt when per-class is :every_attempt" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)
      action = stub_const("WorkerDispatchEveryAttempt", Class.new do
        include Axn
        async :sidekiq
        async_exception_reporting :every_attempt
        def call = raise("Test error")
      end)
      expect(dispatch_and_capture(action)).to be true
    end

    it "falls back to global config when no per-class override" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)
      action = stub_const("WorkerDispatchNoOverride", Class.new do
        include Axn
        async :sidekiq
        def call = raise("Test error")
      end)
      expect(dispatch_and_capture(action)).to be false
    end
  end

  describe "job tags from facets (PRO-2855)" do
    around { |ex| Sidekiq::Testing.fake! { ex.run } }
    before { Sidekiq::Job.clear_all }

    let(:last_job_tags) { -> { Sidekiq::Job.jobs.last["tags"] } }

    it "surfaces tag + dimension facets as name:value job tags" do
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("company_id:42", "plan:pro")
    end

    it "resolves from raw enqueued inputs (an omitted defaulted field yields no tag)" do
      # `plan` has `default: "free"`, but defaults are not applied at enqueue (they'd double-run at
      # perform and could drift), so an omitted `plan` produces no tag rather than "plan:free".
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 7)
      expect(last_job_tags.call).to contain_exactly("company_id:7")
    end

    it "keeps a same-named tag and dimension as two distinct job tags" do
      Actions::Async::TestActionSidekiqDupFacetName.call_async(account_id: 7, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("account:7", "account:pro")
    end

    it "honors sidekiq_job_tag_sources = [:dimension] (bounded only)" do
      allow(Axn.config).to receive(:sidekiq_job_tag_sources).and_return(%i[dimension])
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
    end

    it "honors a per-action sidekiq_job_tag_sources override, independent of the global" do
      # Global default is %i[tag dimension]; this action opts to bounded-only for its own jobs.
      action = stub_const("PerActionBoundedTags", Class.new do
        include Axn
        async :sidekiq
        expects :company_id
        expects :plan, default: "free"
        tag(:company_id) { company_id }
        dimension(:plan) { plan }
        sidekiq_job_tag_sources %i[dimension]
        def call; end
      end)

      action.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
      expect(Axn.config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
    end

    it "honors the override even when the action shadows the generated reader" do
      # The adapter resolves through Axn's override store (Configuration.resolve_override_for), not
      # the shadowable generated reader. Here the shadow claims both sources, but the real per-class
      # override is bounded-only — so honoring the override (not the shadow) yields just the dimension tag.
      action = stub_const("ShadowedTagSourcesReader", Class.new do
        include Axn
        async :sidekiq
        expects :company_id
        expects :plan, default: "free"
        tag(:company_id) { company_id }
        dimension(:plan) { plan }
        sidekiq_job_tag_sources %i[dimension]
        def self.sidekiq_job_tag_sources(*) = %i[tag dimension]
        def call; end
      end)

      action.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
    end

    it "resolves via the store even when the action shadows the bare sidekiq_job_tag_sources reader" do
      # A consumer that defines its own `sidekiq_job_tag_sources` class method (returning garbage)
      # must not derail enqueue-time resolution: routing through Configuration.resolve_override_for
      # reads the store directly (empty here → Axn.config default %i[tag dimension]), so both facets
      # still surface rather than the shadow's value being used and the broad rescue swallowing tags.
      action = stub_const("ShadowedBareTagSources", Class.new do
        include Axn
        async :sidekiq
        expects :company_id
        expects :plan, default: "free"
        tag(:company_id) { company_id }
        dimension(:plan) { plan }
        def self.sidekiq_job_tag_sources(*) = :not_an_array
        def call; end
      end)

      action.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("company_id:42", "plan:pro")
    end

    it "adds no tags key when the action declares no facets" do
      Actions::Async::TestActionSidekiq.call_async(name: "World", age: 25)
      expect(last_job_tags.call).to be_nil
    end

    it "unions facet tags with the worker's static sidekiq_options tags" do
      Actions::Async::TestActionSidekiqTaggedWithStatic.call_async(company_id: 42)
      expect(last_job_tags.call).to contain_exactly("static", "company_id:42")
    end

    it "resolves a model:-derived facet via a real AR lookup" do
      user = User.create!(name: "Ada Lovelace")

      begin
        Actions::Async::TestActionSidekiqModelTagged.call_async(user_id: user.id)
        expect(last_job_tags.call).to contain_exactly("user_name:Ada Lovelace")
      ensure
        User.delete_all
      end
    end
  end
end
