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

    it "carries tags/dimensions alongside async retry context" do
      action_class = build_axn do
        expects :name, type: String
        def call; end
      end
      stub_const("TestAction", action_class)
      instance = TestAction.send(:new, name: "Alice")
      retry_context = double("RetryContext", to_h: { attempt: 2, max_attempts: 5 })

      result = described_class.build(
        action: instance,
        retry_context:,
        tags: { company_id: 42 },
        dimensions: { plan_tier: "pro" },
      )

      expect(result[:async]).to eq(attempt: 2, max_attempts: 5)
      expect(result[:tags]).to eq(company_id: 42)
      expect(result[:dimensions]).to eq(plan_tier: "pro")
    end

    it "maps the axn_stack through resolved_axn_name (class name, axn_name override, or 'Anonymous Axn')" do
      named_class = build_axn
      stub_const("ExceptionContextNamedAction", named_class)

      anon_instance = build_axn.send(:new)
      custom_class = build_axn { axn_name "custom_display" }
      named_instance = ExceptionContextNamedAction.send(:new)
      custom_instance = custom_class.send(:new)

      stack = Axn::Core::NestingTracking._current_axn_stack
      stack.push(anon_instance, named_instance, custom_instance)

      begin
        result = described_class.build(action: custom_instance)
      ensure
        3.times { stack.pop }
      end

      expect(result[:axn_stack]).to eq(["Anonymous Axn", "ExceptionContextNamedAction", "custom_display"])
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

    it "attaches non-empty tags and dimensions under namespaced keys" do
      action_class = build_axn do
        expects :name, type: String
        def call; end
      end
      stub_const("TestAction", action_class)
      instance = TestAction.send(:new, name: "Alice")

      result = described_class.build(
        action: instance,
        tags: { company_id: 42 },
        dimensions: { plan_tier: "pro" },
      )

      expect(result[:tags]).to eq(company_id: 42)
      expect(result[:dimensions]).to eq(plan_tier: "pro")
    end

    it "omits the facet keys entirely when the maps are empty" do
      action_class = build_axn do
        expects :name, type: String
        def call; end
      end
      stub_const("TestAction", action_class)
      instance = TestAction.send(:new, name: "Alice")

      result = described_class.build(action: instance)

      expect(result).not_to have_key(:tags)
      expect(result).not_to have_key(:dimensions)
    end

    it "attaches facet values verbatim without re-formatting them" do
      # A resolved Integer stays an Integer (not GID-stringified like inputs/outputs) —
      # facets are already coerced at resolve time; build must not touch them again.
      action_class = build_axn do
        expects :name, type: String
        def call; end
      end
      stub_const("TestAction", action_class)
      instance = TestAction.send(:new, name: "Alice")

      result = described_class.build(action: instance, tags: { company_id: 7 })

      expect(result[:tags][:company_id]).to be(7)
    end
  end
end
