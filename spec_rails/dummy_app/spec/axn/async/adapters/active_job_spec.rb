# frozen_string_literal: true

RSpec.describe "Axn::Async with ActiveJob adapter" do
  include ActiveJob::TestHelper

  let(:test_action) { Actions::Async::TestActionActiveJob }
  let(:failing_action) { Actions::Async::FailingActionActiveJob }
  let(:expected_log_message) { /Action executed: Hello, World! You are 25 years old\./ }

  before do
    allow(Axn.config.logger).to receive(:info).and_call_original
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  describe ".call_async" do
    it { expect(test_action.call_async(name: "World", age: 25)).to be_a(ActiveJob::Base) }
    it { expect(test_action.call_async(name: "World", age: 25).arguments).to eq([{ name: "World", age: 25 }]) }
    it {
      expect(test_action.call_async(name: "World", age: 25, active: true,
                                    tags: ["test"]).arguments).to eq([{ name: "World", age: 25, active: true, tags: ["test"] }])
    }
  end

  describe "ActiveJob options configuration" do
    it "applies ActiveJob options from async config" do
      job = Actions::Async::TestActionActiveJobWithOptions.call_async(name: "Test", age: 25)
      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "Test", age: 25 }])
      expect(Actions::Async::TestActionActiveJobWithOptions.const_get(:ActiveJobProxy).new.queue_name).to eq("high_priority")
    end

    it "works without custom ActiveJob options" do
      job = test_action.call_async(name: "Test", age: 25)
      expect(job).to be_a(ActiveJob::Base)
      expect(test_action.const_get(:ActiveJobProxy).new.queue_name).to eq("default")
    end
  end

  describe "ActiveJob job execution" do
    it {
      test_action.call_async(name: "World", age: 25)
      expect { perform_enqueued_jobs }.not_to raise_error
    }
    it {
      Actions::Async::TestActionActiveJobNoArgs.call_async
      expect { perform_enqueued_jobs }.not_to raise_error
    }
    it {
      test_action.call_async(name: "Rails", age: 30, active: true, tags: ["test"])
      expect { perform_enqueued_jobs }.not_to raise_error
    }
    it {
      test_action.call_async(name: "World", age: 25)
      test_action.call_async(name: "Rails", age: 30)
      expect { perform_enqueued_jobs }.not_to raise_error
    }

    it "logs action execution details" do
      test_action.call_async(name: "World", age: 25)
      expect { perform_enqueued_jobs }.not_to raise_error
      expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
    end

    it "logs before failing" do
      failing_action.call_async(name: "Test")
      expect { perform_enqueued_jobs }.to raise_error(StandardError, "Intentional failure")
      expect(Axn.config.logger).to have_received(:info).with(/About to fail with name: Test/)
    end
  end

  describe "ActiveJob testing modes" do
    context "when using test adapter (default behavior)" do
      it "enqueues call_async without executing immediately" do
        executed = false
        allow_any_instance_of(test_action).to receive(:call) {
          executed = true
          "Hello, World!"
        }

        expect(test_action.call_async(name: "World", age: 25)).to be_a(ActiveJob::Base)
        expect(executed).to be false
      end

      it "does not log action execution immediately when using test adapter" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).not_to have_received(:info).with(expected_log_message)
      end

      it "enqueues job in ActiveJob queue" do
        expect { test_action.call_async(name: "World", age: 25) }.to change(enqueued_jobs, :size).by(1)
        expect(enqueued_jobs.first[:job]).to eq(test_action::ActiveJobProxy)
      end

      it "can execute enqueued jobs manually with perform_enqueued_jobs" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).not_to have_received(:info).with(expected_log_message)

        perform_enqueued_jobs
        expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
      end
    end

    context "when using inline adapter" do
      around do |example|
        original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :inline
        example.run
      ensure
        ActiveJob::Base.queue_adapter = original_adapter
      end

      it "executes call_async immediately and synchronously" do
        executed = false
        allow_any_instance_of(test_action).to receive(:call) {
          executed = true
          "Hello, World!"
        }

        expect(test_action.call_async(name: "World", age: 25)).to be_a(ActiveJob::Base)
        expect(executed).to be true
      end

      it "logs action execution immediately with inline adapter" do
        test_action.call_async(name: "World", age: 25)
        expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
      end
    end
  end

  describe "ActiveJob error handling" do
    it "enqueues failing jobs" do
      job = failing_action.call_async(name: "Test")
      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "Test" }])
    end

    it "executes failing jobs and raises the error" do
      failing_action.call_async(name: "Test")
      expect { perform_enqueued_jobs }.to raise_error(StandardError, "Intentional failure")
    end
  end
end
