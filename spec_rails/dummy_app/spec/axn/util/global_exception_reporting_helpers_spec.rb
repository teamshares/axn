# frozen_string_literal: true

# Rails-specific tests for GlobalExceptionReportingHelpers
# These tests require ActiveRecord, ActionController, and GlobalID
RSpec.describe Axn::Internal::GlobalExceptionReportingHelpers do
  describe ".format_hash_values" do
    it "converts GlobalID-able objects to GlobalID strings" do
      user = User.create!(name: "Test User")
      result = described_class.format_hash_values({ user: })

      expect(result[:user]).to eq(user.to_global_id.to_s)
    end

    it "converts ActionController::Parameters to hashes" do
      params = ActionController::Parameters.new(name: "Alice", age: 30)
      result = described_class.format_hash_values({ params: })

      expect(result[:params]).to eq({ "name" => "Alice", "age" => 30 })
    end

    it "converts Axn::FormObject to hashes" do
      form_class = Class.new(Axn::FormObject) do
        attr_accessor :name, :age
      end

      form = form_class.new(name: "Alice", age: 30)
      result = described_class.format_hash_values({ form: })

      expect(result[:form]).to eq({ name: "Alice", age: 30 })
    end

    it "recursively formats nested complex objects" do
      form_class = Class.new(Axn::FormObject) do
        attr_accessor :name
      end
      form = form_class.new(name: "Nested")
      payload = { wrapper: { form:, user: User.create!(name: "Test") } }

      result = described_class.format_hash_values(payload)

      expect(result[:wrapper][:form]).to eq({ name: "Nested" })
      expect(result[:wrapper][:user]).to match(%r{\Agid://})
    end
  end

  describe ".format_value_for_retry_command" do
    it "formats ActiveRecord objects as Model.find(id)" do
      user = User.create!(name: "Test User")
      result = described_class.format_value_for_retry_command(user)

      expect(result).to eq("User.find(#{user.id})")
    end

    it "formats GlobalID strings as Model.find(id)" do
      user = User.create!(name: "Test User")
      gid_string = user.to_global_id.to_s

      result = described_class.format_value_for_retry_command(gid_string)
      expect(result).to eq("User.find(\"#{user.id}\")")
    end
  end

  describe ".retry_command" do
    it "generates retry command with ActiveRecord objects" do
      user = User.create!(name: "Test User")

      action_with_model = build_axn do
        expects :user
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("ActionWithModel", action_with_model)

      instance = ActionWithModel.new(user:, name: "Alice")
      result = described_class.retry_command(
        action: instance,
        context: { user:, name: "Alice" },
      )

      expect(result).to eq("ActionWithModel.call(user: User.find(#{user.id}), name: \"Alice\")")
    end
  end
end
