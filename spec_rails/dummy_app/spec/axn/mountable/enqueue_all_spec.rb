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

  describe "enqueue_all on an action relying on the global default (no explicit async)" do
    let(:default_action) do
      stub_const("EnqueueAllGlobalDefaultAction", Class.new do
        include Axn
        expects :item
        enqueues_each :item, from: -> { [1, 2, 3] }
        def call = nil
      end)
    end

    it "applies the default via the shared path (sets _async_via_default, no orphan per-action subclass)" do
      Axn.config.set_default_async(:sidekiq)
      default_action.enqueue_all

      # Must route through the dedicated default worker — a per-action subclass here couldn't be
      # reconstructed in a fresh worker (the action body never re-runs `async`).
      expect(default_action._async_via_default).to be(true)
      expect(default_action.const_defined?(:AxnSidekiqWorker, false)).to be(false)
    end
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

      # The orchestrator runs via the generic Sidekiq Worker subclass; the job carries the
      # orchestrator's class name + serialized kwargs as args (action_class_name, kwargs).
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Axn::Async::EnqueueAllOrchestrator::AxnSidekiqWorker")
      expect(job["args"].size).to eq(2)
      expect(job["args"].first).to eq("Axn::Async::EnqueueAllOrchestrator")
      kwargs = job["args"].last
      expect(kwargs).to include("target_class_name" => "Actions::EnqueueAll::Tester")
      expect(kwargs["static_args"]).to be_empty.or eq("_aj_symbol_keys" => [])
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
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Axn::Async::EnqueueAllOrchestrator::AxnSidekiqWorker")
      expect(job["args"].first).to eq("Axn::Async::EnqueueAllOrchestrator")
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
        # Named so the generic Sidekiq Worker can constantize it when each item enqueues.
        action_class = stub_const("Actions::EnqueueAll::FilterExplodes", Class.new do
          include Axn
          async :sidekiq
          expects :item

          def call; end

          enqueues_each :item, from: -> { [1, 2, 3] } do |item|
            raise "filter exploded for #{item}" if item == 2

            true
          end
        end)

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

  # Regression: enqueue_all used to serialize static_args manually in enqueue_for AND
  # again inside the adapter's call_async pass. On the ActiveJob path (which Sidekiq now
  # uses for arg serialization) the second pass recursed into the already-`_aj_*`-tagged
  # static_args hash and raised ActiveJob::SerializationError -> UnserializableArgument.
  # This drives the REAL call_async (no stubbing of call_async or serialization) with rich
  # static args and asserts it enqueues without raising, then runs the orchestrator job and
  # asserts the static args deserialize back to their original types.
  describe "rich-type static_args round-trip through the real call_async" do
    before do
      User.delete_all
    end

    after do
      User.delete_all
    end

    let(:user) { User.create!(name: "Static User", email: "static@example.com") }

    let(:action_class) do
      stub_const("Actions::EnqueueAll::RichStaticArgsTester", Class.new do
        include Axn
        async :sidekiq

        def self.captured = @captured ||= []

        expects :number
        expects :user, model: User
        expects :scheduled_at, type: Time
        expects :report_kind

        def call
          self.class.captured << { user_class: user.class.name, user_id: user.id, scheduled_at:, report_kind: }
        end

        enqueues_each :number, from: -> { [1, 2] }
      end)
    end

    it "enqueues without raising and round-trips GlobalID, Time, and Symbol static args" do
      scheduled_at = Time.at(1_700_000_000)

      expect do
        action_class.enqueue_all(user:, scheduled_at:, report_kind: :daily)
      end.not_to raise_error

      # One orchestrator job enqueued (the fan-out itself happens when it runs).
      expect(Sidekiq::Queues["default"].size).to eq(1)
      job = Sidekiq::Queues["default"].first
      expect(job["class"]).to eq("Axn::Async::EnqueueAllOrchestrator::AxnSidekiqWorker")
      expect(job["args"].first).to eq("Axn::Async::EnqueueAllOrchestrator")

      # Run the orchestrator inline: it deserializes static_args and fans out the per-number jobs,
      # which (still inline) execute and capture the restored static arg types.
      # The generic Worker perform takes (action_class_name, kwargs) — splat the two args.
      Sidekiq::Testing.inline! do
        job["class"].constantize.send(:new).perform(*job["args"])
      end

      captured = action_class.captured
      expect(captured.size).to eq(2) # numbers 1 and 2
      expect(captured.map { |c| c[:user_class] }.uniq).to eq(["User"])
      expect(captured.map { |c| c[:user_id] }.uniq).to eq([user.id])
      expect(captured.map { |c| c[:scheduled_at] }.uniq).to eq([scheduled_at])
      expect(captured.map { |c| c[:report_kind] }.uniq).to eq([:daily])
    end
  end

  describe "on_enqueue_all with a real ActiveRecord relation" do
    before do
      Profile.delete_all
      User.delete_all
      User.create!(name: "Active A", email: "a@example.com")
      User.create!(name: "Active B", email: "b@example.com")
      User.create!(name: "Deactivated", email: nil)
    end

    after do
      Profile.delete_all
      User.delete_all
    end

    it "hands the block an un-materialized relation supporting efficient aggregation" do
      captured = {}
      action_class = Class.new do
        include Axn
        async :sidekiq
        expects :user, model: User
        def call; end
        enqueues_each :user, from: -> { User.all }
      end
      action_class.on_enqueue_all do |sources:, count:|
        relation = sources[:user]
        captured[:is_relation] = relation.is_a?(ActiveRecord::Relation)
        captured[:loaded_before_use] = relation.loaded? # must be false: un-materialized contract
        captured[:db_count] = relation.count            # aggregate COUNT query, no full load
        active, inactive = relation.partition { |u| u.email.present? }
        captured[:active] = active.size
        captured[:inactive] = inactive.size
        captured[:count] = count
      end

      allow(action_class).to receive(:call_async)
      Axn::Async::EnqueueAllOrchestrator.execute_iteration(action_class)

      expect(captured[:is_relation]).to be(true)
      expect(captured[:loaded_before_use]).to be(false)
      expect(captured[:db_count]).to eq(3)
      expect(captured[:active]).to eq(2)
      expect(captured[:inactive]).to eq(1)
      expect(captured[:count]).to eq(3) # exact enqueued count via find_each
    end

    it "reflects a scoped-relation kwarg override in the sources hash" do
      captured = {}
      action_class = Class.new do
        include Axn
        async :sidekiq
        expects :user, model: User
        def call; end
        enqueues_each :user, from: -> { User.all }
      end
      action_class.on_enqueue_all do |sources:, count:|
        captured[:emails] = sources[:user].pluck(:email)
        captured[:count] = count
      end

      allow(action_class).to receive(:call_async)
      Axn::Async::EnqueueAllOrchestrator.execute_iteration(action_class, user: User.where.not(email: nil))

      expect(captured[:emails]).to contain_exactly("a@example.com", "b@example.com")
      expect(captured[:count]).to eq(2)
    end
  end
end
