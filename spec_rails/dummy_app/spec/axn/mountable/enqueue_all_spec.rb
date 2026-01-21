# frozen_string_literal: true

RSpec.describe "Axn::Async::BatchEnqueue with Sidekiq" do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Queues.clear_all
    # Reset any leaked default async config from other tests
    Axn.config.set_default_async(false)
    # Configure the EnqueueAllOrchestrator to use sidekiq
    Axn.config.set_enqueue_all_async(:sidekiq)
  end

  after do
    # Reset to default
    Axn.config.set_enqueue_all_async(false)
    Axn.config.set_default_async(false)
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
    it "enqueues the EnqueueAllOrchestrator job" do
      result = Actions::EnqueueAll::Tester.enqueue_all

      expect(result).to be_a(String) # Job ID
      expect(Sidekiq::Queues["default"].size).to eq(1)

      # Verify the job is the shared EnqueueAllOrchestrator
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Axn::Async::EnqueueAllOrchestrator")
      expect(job["args"]).to eq([{ "target_class_name" => "Actions::EnqueueAll::Tester", "static_args" => {} }])
    end

    it "iterates and enqueues individual jobs when processed inline" do
      expect do
        Sidekiq::Testing.inline! do
          Actions::EnqueueAll::Tester.enqueue_all
        end
      end.to output(
        /I was called with number: 1.*I was called with number: 2.*I was called with number: 3/m,
      ).to_stdout
    end

    it "does not execute iteration immediately when not in inline mode" do
      expect do
        Actions::EnqueueAll::Tester.enqueue_all
      end.not_to output(/Action executed/).to_stdout

      # Should only enqueue the trigger, not individual jobs
      expect(Sidekiq::Queues["default"].size).to eq(1)
      expect(Sidekiq::Queues["default"].first["class"]).to eq("Axn::Async::EnqueueAllOrchestrator")
    end

    describe "error handling - validation happens upfront" do
      it "raises when async not configured" do
        action_class = Class.new do
          include Axn
          # No async declaration
          expects :item

          def call; end

          enqueues_each :item, from: -> { [1, 2, 3] }
        end

        expect { action_class.enqueue_all }.to raise_error(NotImplementedError, /does not have async configured/)
      end

      it "raises MissingEnqueuesEachError when expects exist but no enqueues_each" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item

          def call; end
          # No enqueues_each
        end

        expect { action_class.enqueue_all }.to raise_error(
          Axn::Async::MissingEnqueuesEachError,
          /not covered by enqueues_each/,
        )
      end

      it "raises when missing required static fields" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item
          expects :required_field

          def call; end

          enqueues_each :item, from: -> { [1, 2, 3] }
        end

        expect { action_class.enqueue_all }.to raise_error(
          ArgumentError,
          /Missing required static field.*required_field/,
        )
      end
    end

    describe "error handling - errors during iteration" do
      # NOTE: These tests call execute_iteration directly since anonymous classes
      # cannot be used with Sidekiq inline (they have no name to constantize).
      # The real-world behavior is identical - errors propagate up.

      it "propagates exception from source lambda" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item

          def call; end

          enqueues_each :item, from: -> { raise "source exploded" }
        end

        expect do
          Axn::Async::EnqueueAllOrchestrator.execute_iteration(action_class)
        end.to raise_error(RuntimeError, "source exploded")
      end

      it "swallows filter block exception and skips item" do
        action_class = Class.new do
          include Axn
          async :sidekiq
          expects :item

          enqueues_each :item, from: -> { [1, 2, 3] } do |item|
            raise "filter exploded for #{item}" if item == 2

            true
          end
        end

        # Filter block errors are swallowed - should not raise
        expect do
          Axn::Async::EnqueueAllOrchestrator.execute_iteration(action_class)
        end.not_to raise_error

        # Should have enqueued 2 jobs (items 1 and 3, skipping 2)
        expect(Sidekiq::Queues["default"].size).to eq(2)
      end
    end
  end

  describe "no expects at all" do
    let(:simple_action) do
      Class.new do
        include Axn
        async :sidekiq

        def self.name = "SimpleAction"

        def call
          puts "SimpleAction executed"
        end
      end
    end

    it "just calls call_async directly" do
      expect(simple_action).to receive(:call_async).with(no_args).and_return("job-id")
      result = simple_action.enqueue_all
      expect(result).to eq("job-id")
    end
  end
end
