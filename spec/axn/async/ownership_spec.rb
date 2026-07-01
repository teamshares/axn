# frozen_string_literal: true

RSpec.describe Axn::Async, ".owned_by?" do
  let(:worker_base) { Axn::Async::Adapters::Sidekiq::Worker }

  # A real Axn action, exposed under a constant so String/Hash class names resolve.
  let!(:action_class) do
    stub_const("OwnershipSpec::RealAction", build_axn do
      def call = nil
    end)
  end

  # A per-action Sidekiq worker subclass (what `async :sidekiq` builds as <Action>::AxnSidekiqWorker).
  let!(:per_action_worker) do
    stub_const("OwnershipSpec::RealAction::AxnSidekiqWorker", Class.new(worker_base))
  end

  # The global-default worker (what the default-async path enqueues).
  let!(:default_worker) do
    stub_const("Axn::Async::Adapters::Sidekiq::DefaultWorker", Class.new(worker_base))
  end

  # A plain, non-Axn class and a plain, non-Axn Sidekiq worker.
  let!(:plain_class) { stub_const("OwnershipSpec::PlainClass", Class.new) }
  let!(:plain_worker) { stub_const("OwnershipSpec::PlainWorker", Class.new) }

  describe "Class input" do
    it "returns true for a real Axn action class (< Axn)" do
      expect(described_class.owned_by?(action_class)).to be true
    end

    it "returns false for a non-Axn class" do
      expect(described_class.owned_by?(plain_class)).to be false
    end

    it "returns true for a per-action AxnSidekiqWorker subclass" do
      expect(described_class.owned_by?(per_action_worker)).to be true
    end

    it "returns true for the global DefaultWorker" do
      expect(described_class.owned_by?(default_worker)).to be true
    end

    it "returns false for a plain (non-Axn) Sidekiq worker class" do
      expect(described_class.owned_by?(plain_worker)).to be false
    end
  end

  describe "String input" do
    it "returns true for a String naming a real action" do
      expect(described_class.owned_by?("OwnershipSpec::RealAction")).to be true
    end

    it "returns true for a String with an ::ActiveJobProxy suffix naming a real action" do
      expect(described_class.owned_by?("OwnershipSpec::RealAction::ActiveJobProxy")).to be true
    end

    it "returns true for a per-action AxnSidekiqWorker name" do
      expect(described_class.owned_by?("OwnershipSpec::RealAction::AxnSidekiqWorker")).to be true
    end

    it "returns true for the DefaultWorker name" do
      expect(described_class.owned_by?("Axn::Async::Adapters::Sidekiq::DefaultWorker")).to be true
    end

    it "returns false for a plain (non-Axn) Sidekiq worker name" do
      expect(described_class.owned_by?("OwnershipSpec::PlainWorker")).to be false
    end

    it "returns false for a String naming no known constant" do
      expect(described_class.owned_by?("OwnershipSpec::DoesNotExist")).to be false
    end
  end

  describe "Hash (raw Sidekiq job hash) input" do
    it "returns true for a string-keyed hash with display_class naming a real action" do
      expect(described_class.owned_by?("display_class" => "OwnershipSpec::RealAction")).to be true
    end

    it "returns true for a symbol-keyed hash with display_class naming a real action" do
      expect(described_class.owned_by?(display_class: "OwnershipSpec::RealAction")).to be true
    end

    it "prefers display_class over wrapped and class" do
      hash = {
        "display_class" => "OwnershipSpec::RealAction",
        "wrapped" => "OwnershipSpec::PlainWorker",
        "class" => "OwnershipSpec::PlainWorker",
      }
      expect(described_class.owned_by?(hash)).to be true
    end

    it "falls back to wrapped (ActiveJob-in-Sidekiq proxy) when display_class is absent" do
      hash = {
        "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        "wrapped" => "OwnershipSpec::RealAction::ActiveJobProxy",
      }
      expect(described_class.owned_by?(hash)).to be true
    end

    it "falls back to class (the enqueued worker) when display_class and wrapped are absent" do
      hash = { "class" => "Axn::Async::Adapters::Sidekiq::DefaultWorker" }
      expect(described_class.owned_by?(hash)).to be true
    end

    it "returns false for a hash whose class is a plain worker" do
      expect(described_class.owned_by?("class" => "OwnershipSpec::PlainWorker")).to be false
    end

    it "returns false for a hash with no recognizable key" do
      expect(described_class.owned_by?("queue" => "default", "jid" => "abc123")).to be false
    end
  end

  describe "blank / unexpected input" do
    it "returns false for nil without raising" do
      expect(described_class.owned_by?(nil)).to be false
    end

    it "returns false for an empty string" do
      expect(described_class.owned_by?("")).to be false
    end

    it "returns false for an empty hash" do
      expect(described_class.owned_by?({})).to be false
    end

    it "returns false for unexpected input types" do
      expect(described_class.owned_by?(42)).to be false
      expect(described_class.owned_by?(:some_symbol)).to be false
    end
  end

  describe "extensibility" do
    it "recognizes a class matched by a registered ownership predicate" do
      custom = stub_const("OwnershipSpec::CustomBackendJob", Class.new)
      described_class.register_ownership_predicate { |klass| klass.name == "OwnershipSpec::CustomBackendJob" }

      expect(described_class.owned_by?(custom)).to be true
    ensure
      # Avoid leaking the predicate into other specs.
      described_class.send(:_ownership_predicates).pop
    end
  end
end
