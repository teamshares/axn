# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "global_id"

RSpec.describe Axn::Enqueueable::ViaActiveJob, type: :job do
  include ActiveJob::TestHelper
  context "Action" do
    let(:action) { build_axn { puts "test" } }

    describe "#perform_later" do
      it "enqueues a job" do
        expect { action.perform_later(this: "this", that: "that") }.not_to raise_error
      end
    end

    describe "#perform_now" do
      subject do
        action.perform_now(name: "Joe", address: "123 Nope")
      end

      it "calls the Action#call directly" do
        expect(action).to receive(:call).with({ name: "Joe", address: "123 Nope" })
        subject
      end

      it "executes immediately" do
        expect { subject }.to output(/test/).to_stdout
      end
    end
  end

  describe "params" do
    let(:action) { build_axn { log "test" } }
    subject { action.perform_later(foo:) }

    context "with string" do
      let(:foo) { "bar" }

      it "doesn't raise" do
        expect { subject }.not_to raise_error
      end
    end

    context "with complex object" do
      let(:foo) { action }

      it "raises serialization error" do
        expect { subject }.to raise_error(ActiveJob::SerializationError)
      end
    end
  end

  describe "ActiveJob serialization" do
    let(:action) { build_axn { puts "test" } }

    it "lets ActiveJob handle serialization validation" do
      # ActiveJob will handle GlobalID conversion and validation automatically
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end
  end

  describe "ActiveJob configuration forwarding" do
    let(:action) { build_axn { puts "test" } }

    it "forwards queue_as configuration" do
      action.queue_as(:high_priority)
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end

    it "forwards set configuration" do
      action.set(wait: 5.seconds)
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end

    it "forwards retry_on configuration" do
      action.retry_on(StandardError, wait: 1.second, attempts: 3)
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end

    it "forwards discard_on configuration" do
      action.discard_on(ArgumentError)
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end

    it "forwards priority configuration" do
      action.priority = 10
      expect { action.perform_later(foo: "bar") }.not_to raise_error
    end
  end

  describe "Inheritance handling" do
    let(:parent_class) do
      Class.new do
        include Axn
        include Axn::Enqueueable::ViaActiveJob
        def self.name
          "ParentAction"
        end

        def call; end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        def self.name
          "ChildAction"
        end
      end
    end

    it "does not share configurations between parent and child classes" do
      parent_class.queue_as(:parent_queue)
      child_class.queue_as(:child_queue)

      expect(parent_class._activejob_configs).to eq([%i[queue_as parent_queue]])
      expect(child_class._activejob_configs).to eq([%i[queue_as child_queue]])
    end

    it "applies only child class configurations to child job" do
      child_class.queue_as(:child_queue)
      child_class.retry_on(StandardError, attempts: 3)

      expect { child_class.perform_later(foo: "bar") }.not_to raise_error
    end
  end
end
