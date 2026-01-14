# frozen_string_literal: true

RSpec.describe "Axn::Async::BatchEnqueue with Sidekiq" do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Queues.clear_all
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
    it "on success" do
      result = Actions::EnqueueAll::Tester.enqueue_all
      expect(result).to eq(true)
    end

    it "enqueues individual jobs" do
      Actions::EnqueueAll::Tester.enqueue_all

      # Should have enqueued 3 individual Tester jobs (from: -> { [1, 2, 3] })
      expect(Sidekiq::Queues["default"].size).to eq(3)

      jobs = Sidekiq::Queues["default"].to_a
      expect(jobs.map { |j| j["args"] }).to contain_exactly(
        [{ "number" => 1 }],
        [{ "number" => 2 }],
        [{ "number" => 3 }],
      )
    end

    describe "error handling" do
      it "propagates exception from source lambda" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item

          def call; end

          enqueue_each :item, from: -> { raise "source exploded" }
        end

        expect { action_class.enqueue_all }.to raise_error(RuntimeError, "source exploded")
      end

      it "propagates exception from filter block" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item

          def call; end

          enqueue_each :item, from: -> { [1, 2, 3] } do |item|
            raise "filter exploded for #{item}" if item == 2
            true
          end
        end

        expect { action_class.enqueue_all }.to raise_error(RuntimeError, "filter exploded for 2")
      end

      it "raises when missing required static fields" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item
          expects :required_field

          def call; end

          enqueue_each :item, from: -> { [1, 2, 3] }
        end

        expect { action_class.enqueue_all }.to raise_error(
          ArgumentError,
          /Missing required static field.*required_field/,
        )
      end
    end
  end

  describe ".enqueue_all_async" do
    it "enqueues the enqueue_all action itself" do
      result = Actions::EnqueueAll::Tester.enqueue_all_async

      expect(result).to be_a(String) # Job ID
      expect(Sidekiq::Queues["default"].size).to eq(1) # Should enqueue 1 job (the enqueue_all action itself)

      # Verify the job is the enqueue_all action, not individual Tester jobs
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Actions::EnqueueAll::Tester::BatchEnqueueAll")
      expect(job["args"]).to eq([{}])
    end

    it "executes the enqueue_all action when processed inline" do
      # When run inline, the EnqueueAll action runs immediately, iterates, and
      # enqueues individual Tester jobs, which then also run inline.
      #
      # Verify by capturing stdout from the individual action executions.
      expect do
        Sidekiq::Testing.inline! do
          Actions::EnqueueAll::Tester.enqueue_all_async
        end
      end.to output(
        /I was called with number: 1.*I was called with number: 2.*I was called with number: 3/m,
      ).to_stdout
    end

    it "does not execute iteration immediately when not in inline mode" do
      # This should NOT produce the "Action executed" output immediately
      expect do
        Actions::EnqueueAll::Tester.enqueue_all_async
      end.not_to output(/Action executed/).to_stdout

      # Should only enqueue the enqueue_all action itself, not individual jobs
      expect(Sidekiq::Queues["default"].size).to eq(1)

      # Verify the job is the enqueue_all action, not individual Tester jobs
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Actions::EnqueueAll::Tester::BatchEnqueueAll")
    end

    # NOTE: Error handling for enqueue_all_async is tested via the synchronous
    # enqueue_all tests above. Async versions require named classes for Sidekiq,
    # but the error behavior is identical since enqueue_all_async just wraps
    # enqueue_all in a background job.
  end
end
