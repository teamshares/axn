# frozen_string_literal: true

# Rails-specific tests for ExceptionContext
# These tests require ActiveRecord, ActionController, and GlobalID
RSpec.describe Axn::Internal::ExceptionContext do
  describe ".build" do
    it "converts GlobalID-able objects to GlobalID strings in inputs" do
      user = User.create!(name: "Test User")

      action_class = build_axn do
        expects :user

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, user:)
      result = described_class.build(action: instance)

      expect(result[:inputs][:user]).to eq(user.to_global_id.to_s)
    end

    it "converts ActionController::Parameters to hashes in inputs" do
      params = ActionController::Parameters.new(name: "Alice", age: 30)

      action_class = build_axn do
        expects :params

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, params:)
      result = described_class.build(action: instance)

      expect(result[:inputs][:params]).to eq({ "name" => "Alice", "age" => 30 })
    end

    it "converts Axn::FormObject to hashes in inputs" do
      form_class = Class.new(Axn::FormObject) do
        attr_accessor :name, :age
      end

      form = form_class.new(name: "Alice", age: 30)

      action_class = build_axn do
        expects :form

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, form:)
      result = described_class.build(action: instance)

      expect(result[:inputs][:form]).to eq({ name: "Alice", age: 30 })
    end

    it "recursively formats nested complex objects in inputs" do
      form_class = Class.new(Axn::FormObject) do
        attr_accessor :name
      end
      form = form_class.new(name: "Nested")
      user = User.create!(name: "Test")

      action_class = build_axn do
        expects :wrapper, type: Hash

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, wrapper: { form:, user: })
      result = described_class.build(action: instance)

      expect(result[:inputs][:wrapper][:form]).to eq({ name: "Nested" })
      expect(result[:inputs][:wrapper][:user]).to match(%r{\Agid://})
    end

    # Parameters#to_unsafe_h recursively rebuilds every nested container, so it blows the stack on a
    # cycle BEFORE any guard of ours can see the repeated container. Left unhandled it took the whole
    # report with it, since building this context runs inside the guard that reports the exception.
    #
    # A cycle gets inside Parameters only by in-place mutation of an already-nested Array: `new` and
    # `[]=` both convert eagerly, so they raise at assignment rather than storing one.
    it "falls back to a placeholder for Parameters holding a self-referential value, keeping the report" do
      params = ActionController::Parameters.new(list: [1], other: "kept")
      nested = params[:list]
      nested << nested

      action_class = build_axn do
        expects :payload

        def call
          # no-op
        end
      end
      stub_const("TestAction", action_class)

      instance = TestAction.send(:new, payload: params)

      expect { described_class.build(action: instance) }.not_to raise_error
      expect(described_class.build(action: instance)[:inputs][:payload]).to eq("{...}")
    end
  end
end
