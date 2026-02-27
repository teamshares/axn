# frozen_string_literal: true

# =============================================================================
# Axn-MCP Interface Contract Spec
# =============================================================================
#
# This spec documents and tests the axn interface used by the axn-mcp gem.
# Changes that break these specs require corresponding updates to axn-mcp.
#
# axn-mcp relies on:
# - Core: include Axn, expects/exposes with full DSL
# - Invocation: .call/.call! returning Axn::Result
# - Result/Failure: result.ok?, result.exception (Axn::Failure for fail!)
# - Field config access: internal_field_configs, external_field_configs, subfield_configs
# - Field config shape: field, validations, default, preprocess, sensitive, metadata, description
# - Internal API: Axn::Internal::FieldConfig.optional?(config)
# - Testing: Axn::Testing::SpecHelpers#build_axn
# =============================================================================

require "spec_helper"

RSpec.describe "Axn-MCP interface contract" do
  describe "Core action with expects/exposes" do
    let(:tool_action) do
      Class.new do
        include Axn

        expects :server_context, type: Hash, optional: true, description: "MCP server context"
        expects :name, type: String, description: "The user's name"
        expects :count, type: Integer, default: 1
        expects :active, type: :boolean, optional: true

        exposes :greeting, type: String, description: "The greeting message"
        exposes :processed_count, type: Integer, optional: true

        def call
          expose greeting: "Hello, #{name}!"
          expose processed_count: count * 2
        end
      end
    end

    it "includes Axn module" do
      expect(tool_action.ancestors).to include(Axn::Core)
    end

    it "supports expects with type, optional, default, description" do
      result = tool_action.call(name: "Alice")
      expect(result).to be_ok
      expect(result.greeting).to eq("Hello, Alice!")
      expect(result.processed_count).to eq(2)
    end

    it "supports exposes with type, optional, description" do
      result = tool_action.call(name: "Bob", count: 5)
      expect(result.greeting).to eq("Hello, Bob!")
      expect(result.processed_count).to eq(10)
    end
  end

  describe "Expects with validation options" do
    it "supports inclusion validation" do
      action = Class.new do
        include Axn
        expects :status, inclusion: { in: %w[active inactive pending] }

        def call; end
      end

      expect(action.call(status: "active")).to be_ok
      expect(action.call(status: "unknown")).not_to be_ok
    end

    it "supports numericality validation" do
      action = Class.new do
        include Axn
        expects :amount, numericality: { greater_than: 0 }

        def call; end
      end

      expect(action.call(amount: 10)).to be_ok
      expect(action.call(amount: -1)).not_to be_ok
    end

    it "supports numericality with only_integer" do
      action = Class.new do
        include Axn
        expects :count, numericality: { only_integer: true }

        def call; end
      end

      expect(action.call(count: 5)).to be_ok
    end

    it "supports nested type: Hash with subfields" do
      action = Class.new do
        include Axn
        expects :user, type: Hash
        expects :name, type: String, on: :user
        expects :age, type: Integer, optional: true, on: :user

        def call; end
      end

      expect(action.call(user: { name: "Alice", age: 30 })).to be_ok
      expect(action.call(user: { name: "Bob" })).to be_ok
    end
  end

  describe "Invocation API" do
    describe ".call" do
      it "returns Axn::Result" do
        action = Class.new do
          include Axn

          def call; end
        end

        result = action.call
        expect(result).to be_a(Axn::Result)
      end

      it "returns ok result on success" do
        action = Class.new do
          include Axn

          exposes :value, type: Integer, optional: true

          def call
            expose value: 42
          end
        end

        result = action.call
        expect(result).to be_ok
        expect(result.value).to eq(42)
      end

      it "returns failed result on fail!" do
        action = Class.new do
          include Axn

          def call
            fail! "Something went wrong"
          end
        end

        result = action.call
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::Failure)
      end
    end

    describe ".call!" do
      it "returns Axn::Result on success" do
        action = Class.new do
          include Axn

          exposes :data, type: String, optional: true

          def call
            expose data: "success"
          end
        end

        result = action.call!
        expect(result).to be_a(Axn::Result)
        expect(result).to be_ok
        expect(result.data).to eq("success")
      end

      it "raises Axn::Failure on fail!" do
        action = Class.new do
          include Axn

          def call
            fail! "Controlled failure"
          end
        end

        expect { action.call! }.to raise_error(Axn::Failure, "Controlled failure")
      end

      it "raises original exception on unhandled error" do
        action = Class.new do
          include Axn

          def call
            raise ArgumentError, "Bad input"
          end
        end

        expect { action.call! }.to raise_error(ArgumentError, "Bad input")
      end
    end
  end

  describe "Result API" do
    describe "result.ok?" do
      it "returns true for success" do
        action = Class.new do
          include Axn

          def call; end
        end

        expect(action.call.ok?).to be true
      end

      it "returns false for failure" do
        action = Class.new do
          include Axn

          def call
            fail! "error"
          end
        end

        expect(action.call.ok?).to be false
      end
    end

    describe "result.exception" do
      it "is nil on success" do
        action = Class.new do
          include Axn

          def call; end
        end

        expect(action.call.exception).to be_nil
      end

      it "is Axn::Failure instance on fail!" do
        action = Class.new do
          include Axn

          def call
            fail! "failure message"
          end
        end

        result = action.call
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception.message).to eq("failure message")
      end
    end
  end

  describe "Field config access for schema generation" do
    let(:action_with_fields) do
      Class.new do
        include Axn

        expects :name, type: String, description: "User name"
        expects :count, type: Integer, default: 0
        expects :active, type: :boolean, optional: true
        expects :data, type: Hash, optional: true
        expects :nested_field, type: String, on: :data, optional: true

        exposes :output, type: String, description: "The output"
        exposes :status, type: String, optional: true

        def call
          expose output: "done"
        end
      end
    end

    describe "internal_field_configs" do
      it "is an array" do
        expect(action_with_fields.internal_field_configs).to be_an(Array)
      end

      it "contains configs for each expects declaration" do
        fields = action_with_fields.internal_field_configs.map(&:field)
        expect(fields).to include(:name, :count, :active, :data)
      end

      it "each config responds to field" do
        config = action_with_fields.internal_field_configs.first
        expect(config).to respond_to(:field)
        expect(config.field).to be_a(Symbol)
      end

      it "each config responds to validations returning Hash" do
        config = action_with_fields.internal_field_configs.find { |c| c.field == :name }
        expect(config).to respond_to(:validations)
        expect(config.validations).to be_a(Hash)
      end

      it "each config responds to default" do
        config = action_with_fields.internal_field_configs.find { |c| c.field == :count }
        expect(config).to respond_to(:default)
        expect(config.default).to eq(0)
      end

      it "each config responds to preprocess" do
        config = action_with_fields.internal_field_configs.first
        expect(config).to respond_to(:preprocess)
      end

      it "each config responds to sensitive" do
        config = action_with_fields.internal_field_configs.first
        expect(config).to respond_to(:sensitive)
      end

      it "each config responds to metadata" do
        config = action_with_fields.internal_field_configs.find { |c| c.field == :name }
        expect(config).to respond_to(:metadata)
        expect(config.metadata).to be_a(Hash)
      end

      it "each config responds to description via metadata" do
        config = action_with_fields.internal_field_configs.find { |c| c.field == :name }
        expect(config).to respond_to(:description)
        expect(config.description).to eq("User name")
      end

      it "validations hash contains type info" do
        config = action_with_fields.internal_field_configs.find { |c| c.field == :name }
        expect(config.validations).to have_key(:type)
      end
    end

    describe "external_field_configs" do
      it "is an array" do
        expect(action_with_fields.external_field_configs).to be_an(Array)
      end

      it "contains configs for each exposes declaration" do
        fields = action_with_fields.external_field_configs.map(&:field)
        expect(fields).to include(:output, :status)
      end

      it "each config has same shape as internal_field_configs" do
        config = action_with_fields.external_field_configs.first
        expect(config).to respond_to(:field)
        expect(config).to respond_to(:validations)
        expect(config).to respond_to(:default)
        expect(config).to respond_to(:preprocess)
        expect(config).to respond_to(:sensitive)
        expect(config).to respond_to(:metadata)
        expect(config).to respond_to(:description)
      end
    end

    describe "subfield_configs" do
      it "is an array" do
        expect(action_with_fields.subfield_configs).to be_an(Array)
      end

      it "contains configs for expects with on: option" do
        fields = action_with_fields.subfield_configs.map(&:field)
        expect(fields).to include(:nested_field)
      end

      it "each config responds to on (parent field)" do
        config = action_with_fields.subfield_configs.find { |c| c.field == :nested_field }
        expect(config).to respond_to(:on)
        expect(config.on).to eq(:data)
      end

      it "each config has same base attributes as field configs" do
        config = action_with_fields.subfield_configs.first
        expect(config).to respond_to(:field)
        expect(config).to respond_to(:validations)
        expect(config).to respond_to(:default)
        expect(config).to respond_to(:preprocess)
        expect(config).to respond_to(:sensitive)
        expect(config).to respond_to(:metadata)
      end
    end
  end

  describe "Axn::Internal::FieldConfig.optional?" do
    it "is a module function" do
      expect(Axn::Internal::FieldConfig).to respond_to(:optional?)
    end

    it "returns false for required field (presence: true)" do
      action = Class.new do
        include Axn
        expects :required_field, type: String

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :required_field }
      expect(Axn::Internal::FieldConfig.optional?(config)).to be false
    end

    it "returns true for optional field (optional: true)" do
      action = Class.new do
        include Axn
        expects :optional_field, type: String, optional: true

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :optional_field }
      expect(Axn::Internal::FieldConfig.optional?(config)).to be true
    end

    it "returns true for field with allow_blank: true" do
      action = Class.new do
        include Axn
        expects :blank_allowed, type: String, allow_blank: true

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :blank_allowed }
      expect(Axn::Internal::FieldConfig.optional?(config)).to be true
    end

    it "returns true for boolean type (no presence validation)" do
      action = Class.new do
        include Axn
        expects :flag, type: :boolean

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :flag }
      expect(Axn::Internal::FieldConfig.optional?(config)).to be true
    end
  end

  describe "Axn::Testing::SpecHelpers" do
    include Axn::Testing::SpecHelpers

    describe "#build_axn" do
      it "is available as a helper method" do
        expect(self).to respond_to(:build_axn)
      end

      it "returns a class that includes Axn" do
        action = build_axn
        expect(action.ancestors).to include(Axn::Core)
      end

      it "evaluates block in class context" do
        action = build_axn do
          expects :input, type: String

          def call
            expose output: input.upcase
          end
        end
        action.exposes :output, type: String, optional: true

        result = action.call(input: "hello")
        expect(result.output).to eq("HELLO")
      end

      it "allows defining expects and exposes" do
        action = build_axn do
          expects :value, type: Integer, default: 10
          exposes :doubled, type: Integer, optional: true

          def call
            expose doubled: value * 2
          end
        end

        result = action.call
        expect(result.doubled).to eq(20)
      end
    end
  end

  describe "Validation options used by axn-mcp schema builder" do
    it "inclusion :in is accessible in validations hash" do
      action = Class.new do
        include Axn
        expects :status, inclusion: { in: %w[a b c] }

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :status }
      expect(config.validations[:inclusion]).to be_a(Hash)
      expect(config.validations[:inclusion][:in]).to eq(%w[a b c])
    end

    it "inclusion :within is accessible in validations hash" do
      action = Class.new do
        include Axn
        expects :priority, inclusion: { within: [1, 2, 3] }

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :priority }
      expect(config.validations[:inclusion][:within]).to eq([1, 2, 3])
    end

    it "numericality options are accessible in validations hash" do
      action = Class.new do
        include Axn
        expects :amount, numericality: { greater_than: 0, only_integer: true }

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :amount }
      expect(config.validations[:numericality][:greater_than]).to eq(0)
      expect(config.validations[:numericality][:only_integer]).to eq(true)
    end

    it "type option is normalized to hash with :klass key" do
      action = Class.new do
        include Axn
        expects :name, type: String

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :name }
      expect(config.validations[:type]).to be_a(Hash)
      expect(config.validations[:type][:klass]).to eq(String)
    end

    it "model option is accessible in validations hash" do
      stub_const("User", Class.new)
      action = Class.new do
        include Axn
        expects :user, model: true

        def call; end
      end

      config = action.internal_field_configs.find { |c| c.field == :user }
      expect(config.validations).to have_key(:model)
    end
  end

  describe "Axn::Failure exception class" do
    it "exists and is a StandardError" do
      expect(Axn::Failure).to be < StandardError
    end

    it "has a message accessor" do
      failure = Axn::Failure.new("test message")
      expect(failure.message).to eq("test message")
    end

    it "has a default message when none provided" do
      failure = Axn::Failure.new
      expect(failure.message).to eq("Execution was halted")
    end

    it "responds to default_message?" do
      default_failure = Axn::Failure.new
      custom_failure = Axn::Failure.new("custom")

      expect(default_failure.default_message?).to be true
      expect(custom_failure.default_message?).to be false
    end
  end
end
