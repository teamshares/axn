# frozen_string_literal: true

RSpec.describe "Axn::Async with Sidekiq adapter", :sidekiq do
  let(:test_action) { Actions::Async::TestActionSidekiq }
  let(:failing_action) { Actions::Async::FailingActionSidekiq }
  let(:expected_log_message) { /Action executed: Hello, World! You are 25 years old\./ }

  before do
    Sidekiq::Testing.inline!
    Sidekiq.strict_args!(false)
    allow(Axn.config.logger).to receive(:info).and_call_original
    Sidekiq::Job.jobs.clear
  end

  after do
    Sidekiq::Testing.fake!
    Sidekiq.strict_args!(true)
    Sidekiq::Job.jobs.clear
  end

  describe ".call_async" do
    it { expect(test_action.call_async(name: "World", age: 25)).to match(/\A[0-9a-f]{24}\z/) }
    it { expect(test_action.call_async(name: "World", age: 25, active: true, tags: ["test"])).to match(/\A[0-9a-f]{24}\z/) }
  end

  describe "GlobalID integration" do
    let(:user) { double("User", to_global_id: double("GlobalID", to_s: "gid://test/User/123")) }
    let(:global_id_action) { Actions::Async::TestActionSidekiqGlobalId }

    before do
      allow(GlobalID::Locator).to receive(:locate).with("gid://test/User/123").and_return(user)
    end

    it { expect(global_id_action.call_async(name: "World", user:)).to match(/\A[0-9a-f]{24}\z/) }

    it "converts GlobalID objects during execution" do
      expect_any_instance_of(global_id_action).to receive(:perform).with(
        hash_including("name" => "World", "user_as_global_id" => "gid://test/User/123"),
      ).and_call_original

      expect(global_id_action.call_async(name: "World", user:)).to match(/\A[0-9a-f]{24}\z/)
    end
  end

  describe "Sidekiq options configuration" do
    it "applies sidekiq_options from async config" do
      expect(Actions::Async::TestActionSidekiqWithOptions.sidekiq_options).to include(
        "queue" => "high_priority",
        "retry" => 3,
      )
      expect(Actions::Async::TestActionSidekiqWithOptions.call_async(name: "Test", age: 25)).to match(/\A[0-9a-f]{24}\z/)
    end

    it { expect(test_action.sidekiq_options).to be_a(Hash) }
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
        Sidekiq::Job.jobs.clear
      end

      after do
        Sidekiq::Testing.inline!
        Sidekiq::Job.jobs.clear
      end

      it "enqueues job in Sidekiq jobs array" do
        Sidekiq::Job.jobs.clear
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
        job_data["class"].constantize.new.perform(job_data["args"].first)

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

      it { expect { test_action.call_async(name: "Test", age: 25, unserializable: unserializable_object) }.to raise_error(RuntimeError, "Cannot serialize") }
      it { expect { test_action.call_async(name: "Test", age: 25, complex: unserializable_object) }.to raise_error(RuntimeError, "Cannot serialize") }
    end
  end
end
