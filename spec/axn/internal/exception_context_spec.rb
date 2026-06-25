# frozen_string_literal: true

require "globalid"

RSpec.describe Axn::Internal::ExceptionContext do
  describe ".build" do
    it "builds context with formatted inputs and outputs" do
      action_class = build_axn do
        expects :name, type: String
        expects :age, type: Integer

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, name: "Alice", age: 30)

      result = described_class.build(action: instance)

      expect(result).to eq({
                             inputs: { name: "Alice", age: 30 },
                             outputs: {},
                           })
    end

    it "preserves nested hash and array structures" do
      action_class = build_axn do
        expects :data, type: Hash

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, data: {
                                   outer: { inner: "x" },
                                   list: [{ a: 1 }, { b: 2 }],
                                 })

      result = described_class.build(action: instance)

      expect(result[:inputs][:data]).to eq({
                                             outer: { inner: "x" },
                                             list: [{ a: 1 }, { b: 2 }],
                                           })
    end

    it "includes async context when provided" do
      action_class = build_axn do
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, name: "Alice")
      retry_context = double("RetryContext", to_h: { attempt: 2, max_attempts: 5 })

      result = described_class.build(
        action: instance,
        retry_context:,
      )

      expect(result).to eq({
                             inputs: { name: "Alice" },
                             outputs: {},
                             async: { attempt: 2, max_attempts: 5 },
                           })
    end

    context "with unpersisted ActiveRecord-like objects" do
      let(:unpersisted_class) do
        Class.new do
          def self.name = "FakeRecord"

          def to_global_id
            raise URI::GID::MissingModelIdError, "Unable to create a GlobalID without a model id"
          end

          def id = nil

          def respond_to?(method, include_private: false)
            %i[to_global_id id].include?(method) || super
          end

          def inspect = "#<FakeRecord (new record)>"
        end
      end

      let(:persisted_class) do
        fake_gid = double("GlobalID", to_s: "gid://app/FakeRecord/42")
        Class.new do
          define_method(:to_global_id) { fake_gid }
          def id = 42
          def self.name = "FakeRecord"

          def respond_to?(method, include_private: false)
            %i[to_global_id id].include?(method) || super
          end
        end
      end

      it "does not raise when an input is an unpersisted AR-like object" do
        unpersisted = unpersisted_class.new

        action_class = build_axn do
          expects :record

          def call; end
        end

        stub_const("TestAction", action_class)
        instance = TestAction.send(:new, record: unpersisted)

        expect { described_class.build(action: instance) }.not_to raise_error
      end

      it "formats an unpersisted AR-like input as an informative string" do
        unpersisted = unpersisted_class.new

        action_class = build_axn do
          expects :record

          def call; end
        end

        stub_const("TestAction", action_class)
        instance = TestAction.send(:new, record: unpersisted)

        result = described_class.build(action: instance)

        expect(result[:inputs][:record]).to eq("#<FakeRecord (unpersisted)>")
      end

      it "still serializes a persisted AR-like input as a GID string" do
        persisted = persisted_class.new

        action_class = build_axn do
          expects :record

          def call; end
        end

        stub_const("TestAction", action_class)
        instance = TestAction.send(:new, record: persisted)

        result = described_class.build(action: instance)

        expect(result[:inputs][:record]).to eq("gid://app/FakeRecord/42")
      end
    end
  end
end
