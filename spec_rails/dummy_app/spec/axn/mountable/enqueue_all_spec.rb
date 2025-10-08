# frozen_string_literal: true

RSpec.describe "Axn::Mountable with enqueue_all" do
  before do
    Sidekiq::Testing.fake!
  end

  describe "core call behavior" do
    it "foreground" do
      expect do
        Actions::EnqueueAll::Tester.call(number: 1)
      end.to output(
        "Action executed: I was called with number: 1 | instance_helper | class_helper\n",
      ).to_stdout

      result = Actions::EnqueueAll::Tester.call(number: 1)
      expect(result).to be_ok
    end

    it "background" do
      allow(Actions::EnqueueAll::Tester).to receive(:call_async).and_call_original

      result = Actions::EnqueueAll::Tester.call_async(number: 1)

      expect(result).to be_a(String) # Job ID
      expect(Actions::EnqueueAll::Tester).to have_received(:call_async).once
    end
  end

  describe ".enqueue_all" do
    it "has access to instance and class helpers from superclass" do
      expect do
        Actions::EnqueueAll::Tester.enqueue_all(max: 2)
      end.to output(
        /About to enqueue_all: max: 2 \| instance_helper \| class_helper\n/,
      ).to_stdout
    end

    it "on success" do
      result = Actions::EnqueueAll::Tester.enqueue_all(max: 2)
      expect(result).to eq(true)
    end

    it "on error" do
      expect do
        Actions::EnqueueAll::Tester.enqueue_all(max: 4)
      end.to raise_error(RuntimeError, "don't like 4s")
    end

    # it "on error" do
    #   pending "TODO: eventually we should support raising error message from parent's mapping?"
    #   result = Actions::EnqueueAll::Tester.enqueue_all(max: 4)
    #   expect(result).to raise_error(Axn::Failure, "bad times")
    # end
  end

  describe ".enqueue_all_async" do
    it "enqueues the enqueue_all action itself" do
      Sidekiq::Queues.clear_all

      result = Actions::EnqueueAll::Tester.enqueue_all_async(max: 2)

      expect(result).to be_a(String) # Job ID
      expect(Sidekiq::Queues["default"].size).to eq(1) # Should enqueue 1 job (the enqueue_all action itself)

      # Verify the job is the enqueue_all action, not individual Tester jobs
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Actions::EnqueueAll::Tester::Axns::EnqueueAll")
      expect(job["args"]).to eq([{ "max" => 2 }])
    end

    it "executes the enqueue_all action when processed inline" do
      # NOTE: RSpec mocks on call_async interfere with inline execution
      # because they intercept the call before it can be properly enqueued
      expect do
        Sidekiq::Testing.inline! do
          Actions::EnqueueAll::Tester.enqueue_all_async(max: 2)
        end
      end.to output(
        /(?:.*Sidekiq.*connecting to Redis.*)?About to enqueue_all: max: 2 \| instance_helper \| class_helper\n.*Action executed: I was called with number: 1 \| instance_helper \| class_helper\n.*Action executed: I was called with number: 2 \| instance_helper \| class_helper/m, # rubocop:disable Layout/LineLength
      ).to_stdout
    end

    it "handles errors in enqueue_all_via block when processed inline" do
      expect do
        Sidekiq::Testing.inline! do
          Actions::EnqueueAll::Tester.enqueue_all_async(max: 4)
        end
      end.to raise_error(RuntimeError, "don't like 4s")
    end

    it "does not execute enqueue_all_via block immediately when not in inline mode" do
      Sidekiq::Queues.clear_all

      # This should NOT produce the "About to enqueue_all" output immediately
      expect do
        Actions::EnqueueAll::Tester.enqueue_all_async(max: 2)
      end.not_to output(/About to enqueue_all/).to_stdout

      # Should only enqueue the enqueue_all action itself, not individual jobs
      expect(Sidekiq::Queues["default"].size).to eq(1)

      # Verify the job is the enqueue_all action, not individual Tester jobs
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Actions::EnqueueAll::Tester::Axns::EnqueueAll")
      expect(job["args"]).to eq([{ "max" => 2 }])
    end

    it "calling enqueue_all directly enqueues individual Tester jobs" do
      Sidekiq::Queues.clear_all

      # Call enqueue_all directly (not async) - this executes the enqueue_all_via block immediately
      # and enqueues the individual Tester jobs
      Actions::EnqueueAll::Tester.enqueue_all(max: 3)

      # Should have enqueued 3 individual Tester jobs
      expect(Sidekiq::Queues["default"].size).to eq(3)

      jobs = Sidekiq::Queues["default"].to_a
      expect(jobs.map { |j| j["args"] }).to eq([
                                                 [{ "number" => 1 }],
                                                 [{ "number" => 2 }],
                                                 [{ "number" => 3 }],
                                               ])
    end
  end
end
