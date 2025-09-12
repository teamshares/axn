# frozen_string_literal: true

require "spec_helper"
require "active_job/test_helper"

RSpec.describe "Axn::Async with ActiveJob adapter" do
  include ActiveJob::TestHelper

  let(:action_class) do
    build_axn do
      async :active_job
      expects :name, :age

      def call
        "Hello, #{name}! You are #{age} years old."
      end
    end
  end

  describe ".call_async" do
    it "executes the action with the provided context" do
      result = nil

      perform_enqueued_jobs do
        result = action_class.call_async(name: "World", age: 25)
      end

      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end

    it "handles empty context" do
      expect do
        perform_enqueued_jobs do
          action_class.call_async({})
        end
      end.to raise_error(Axn::InboundValidationError)
    end

    it "handles nil context" do
      expect do
        perform_enqueued_jobs do
          action_class.call_async(nil)
        end
      end.to raise_error(Axn::InboundValidationError)
    end

    it "handles complex context" do
      result = nil

      perform_enqueued_jobs do
        result = action_class.call_async(name: "World", age: 25, active: true, tags: ["test"])
      end

      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end
  end

  describe "ActiveJob error handling" do
    it "handles job failures" do
      failing_action_class = build_axn do
        async :active_job
        expects :name

        def call
          raise StandardError, "Intentional failure"
        end
      end

      expect do
        perform_enqueued_jobs do
          failing_action_class.call_async(name: "Test")
        end
      end.to raise_error(StandardError, "Intentional failure")
    end
  end
end
