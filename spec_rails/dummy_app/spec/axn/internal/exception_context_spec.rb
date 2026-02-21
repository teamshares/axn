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

      instance = TestAction.new(user:)
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

      instance = TestAction.new(params:)
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

      instance = TestAction.new(form:)
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

      instance = TestAction.new(wrapper: { form:, user: })
      result = described_class.build(action: instance)

      expect(result[:inputs][:wrapper][:form]).to eq({ name: "Nested" })
      expect(result[:inputs][:wrapper][:user]).to match(%r{\Agid://})
    end

    it "generates retry command with ActiveRecord objects formatted as Model.find(id)" do
      user = User.create!(name: "Test User")

      action_class = build_axn do
        expects :user
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("ActionWithModel", action_class)

      instance = ActionWithModel.new(user:, name: "Alice")

      original_value = Axn.config._include_retry_command_in_exceptions
      begin
        Axn.config._include_retry_command_in_exceptions = true

        result = described_class.build(action: instance)

        expect(result[:retry_command]).to eq("ActionWithModel.call(user: User.find(#{user.id}), name: \"Alice\")")
      ensure
        Axn.config._include_retry_command_in_exceptions = original_value
      end
    end
  end
end
