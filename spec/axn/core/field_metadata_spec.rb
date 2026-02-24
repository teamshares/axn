# frozen_string_literal: true

RSpec.describe "Field metadata" do
  describe "expects with description" do
    let(:action) do
      build_axn do
        expects :name, description: "The user's full name"
      end
    end

    it "stores description in metadata, not validations" do
      config = action.internal_field_configs.first
      expect(config.metadata).to eq({ description: "The user's full name" })
      expect(config.validations.keys).not_to include(:description)
    end

    it "provides a description accessor" do
      config = action.internal_field_configs.first
      expect(config.description).to eq("The user's full name")
    end

    it "does not affect validation behavior" do
      result = action.call(name: "Alice")
      expect(result).to be_ok
    end
  end

  describe "exposes with description" do
    let(:action) do
      build_axn do
        exposes :computed_value, description: "The computation result"

        def call
          expose computed_value: 42
        end
      end
    end

    it "stores description in metadata" do
      config = action.external_field_configs.first
      expect(config.metadata).to eq({ description: "The computation result" })
      expect(config.description).to eq("The computation result")
    end

    it "does not affect validation behavior" do
      result = action.call
      expect(result).to be_ok
      expect(result.computed_value).to eq(42)
    end
  end

  describe "subfield with description" do
    let(:action) do
      build_axn do
        expects :user, type: Hash
        expects :email, on: :user, description: "User's email address"
      end
    end

    it "stores description in SubfieldConfig metadata" do
      config = action.subfield_configs.first
      expect(config.metadata).to eq({ description: "User's email address" })
      expect(config.description).to eq("User's email address")
    end

    it "does not affect validation behavior" do
      result = action.call(user: { email: "test@example.com" })
      expect(result).to be_ok
    end
  end

  describe "single-field enforcement" do
    it "raises ArgumentError when metadata is provided with multiple fields" do
      expect do
        build_axn do
          expects :a, :b, description: "Both fields"
        end
      end.to raise_error(ArgumentError, /can only be provided when declaring a single field/)
    end

    it "allows multiple fields without metadata" do
      expect do
        build_axn do
          expects :a, :b, type: String
        end
      end.not_to raise_error
    end

    it "raises for exposes with multiple fields and metadata" do
      expect do
        build_axn do
          exposes :x, :y, description: "Multiple outputs"
        end
      end.to raise_error(ArgumentError, /can only be provided when declaring a single field/)
    end
  end

  describe "unknown key detection" do
    it "raises ArgumentError for typos in validation keys" do
      expect do
        build_axn do
          expects :value, nummericality: { greater_than: 0 }
        end
      end.to raise_error(ArgumentError, /Unknown key.*:nummericality/)
    end

    it "raises ArgumentError for unregistered metadata keys" do
      expect do
        build_axn do
          expects :value, unregistered_key: "something"
        end
      end.to raise_error(ArgumentError, /Unknown key.*:unregistered_key/)
    end

    it "does not raise for known validation keys" do
      expect do
        build_axn do
          expects :value, numericality: { greater_than: 0 }
        end
      end.not_to raise_error
    end
  end

  describe "custom registered metadata keys" do
    around do |example|
      original_keys = Axn.extension_config.registered_field_metadata_keys.dup
      example.run
      Axn.extension_config.instance_variable_set(:@registered_field_metadata_keys, original_keys)
    end

    it "allows custom keys after registration" do
      Axn.extension_config.register_field_metadata_key(:mcp_title)

      action = build_axn do
        expects :input, mcp_title: "Input Title", description: "Input description"
      end

      config = action.internal_field_configs.first
      expect(config.metadata).to eq({ mcp_title: "Input Title", description: "Input description" })
    end

    it "raises for unregistered custom keys" do
      expect do
        build_axn do
          expects :input, mcp_title: "Input Title"
        end
      end.to raise_error(ArgumentError, /Unknown key.*:mcp_title/)
    end
  end

  describe "backward compatibility" do
    it "defaults metadata to empty hash when no metadata keys provided" do
      action = build_axn do
        expects :value, type: String
      end

      config = action.internal_field_configs.first
      expect(config.metadata).to eq({})
    end

    it "description returns nil when not set" do
      action = build_axn do
        expects :value, type: String
      end

      config = action.internal_field_configs.first
      expect(config.description).to be_nil
    end

    it "known validation keys work as before" do
      action = build_axn do
        expects :count, type: Integer, numericality: { greater_than: 0 }
      end

      result = action.call(count: 5)
      expect(result).to be_ok

      failed = action.call(count: -1)
      expect(failed).not_to be_ok
    end

    it "FieldConfig still has all original attributes" do
      action = build_axn do
        expects :value, type: String, default: "default", preprocess: lambda(&:strip), sensitive: true, description: "A value"
      end

      config = action.internal_field_configs.first
      expect(config.field).to eq(:value)
      expect(config.validations).to be_a(Hash)
      expect(config.default).to eq("default")
      expect(config.preprocess).to be_a(Proc)
      expect(config.sensitive).to be(true)
      expect(config.metadata).to eq({ description: "A value" })
    end
  end

  describe "readers: option" do
    it "raises ArgumentError when readers: false is used without on:" do
      expect do
        build_axn do
          expects :value, readers: false
        end
      end.to raise_error(ArgumentError, /readers: false is only valid for subfields/)
    end

    it "allows readers: true without on: (no-op but valid)" do
      expect do
        build_axn do
          expects :value, readers: true
        end
      end.not_to raise_error
    end

    it "allows readers: false with on: (valid subfield usage)" do
      expect do
        build_axn do
          expects :parent, type: Hash
          expects :child, on: :parent, readers: false
        end
      end.not_to raise_error
    end
  end
end
