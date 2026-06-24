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
end
