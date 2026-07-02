# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::Schema do
  it "builds an input schema with required/optional and descriptions" do
    klass = Class.new do
      include Axn
      expects :name, type: String, description: "the name"
      expects :limit, type: Integer, default: 20, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:type]).to eq("object")
    expect(schema[:properties][:name]).to include(type: "string", description: "the name")
    expect(schema[:properties][:limit]).to include(type: "integer", default: 20)
    expect(schema[:required]).to eq(["name"])
  end

  it "builds an output schema" do
    klass = Class.new do
      include Axn
      exposes :active, type: :boolean
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:active]).to include(type: "boolean")
  end

  it "excludes the ambient_context parent from the input schema" do
    # ambient_context becomes a valid `on:` parent in Phase F; here assert the exclusion constant.
    expect(described_class::EXCLUDED_FROM_INPUT_SCHEMA).to include(:ambient_context)
  end

  it "still emits an enum for a literal array inclusion source" do
    klass = Class.new do
      include Axn
      expects :status, type: String, inclusion: { in: %w[open closed] }
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:status]).to include(type: "string", enum: %w[open closed])
  end

  it "does not raise and skips :enum for a dynamic (method-name) inclusion source" do
    klass = Class.new do
      include Axn
      expects :channel, type: String, inclusion: { in: :valid_channels }

      def valid_channels = %w[email sms]
    end

    schema = nil
    expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error

    expect(schema[:properties][:channel]).to include(type: "string")
    expect(schema[:properties][:channel]).not_to have_key(:enum)
  end

  it "does not leak a Proc default into the schema" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: -> { 20 }
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:limit]).not_to have_key(:default)
  end

  it "still emits a literal default" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: 20, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:limit]).to include(default: 20)
  end

  it "nests subfields under the wire key when the parent field is aliased" do
    klass = Class.new do
      include Axn
      expects :channel, type: Hash, as: :raw_channel
      expects :name, on: :raw_channel, type: String
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    chan = schema[:properties][:channel]
    expect(chan).not_to be_nil
    expect(chan[:properties]).to have_key(:name)
    expect(chan[:required]).to include("name")
  end

  it "does not raise when a dynamic inclusion source drives type inference (no explicit type)" do
    # No `type:` — so json_type_for reaches the inclusion branch. A Symbol/Proc `in:` is a
    # runtime-resolved source, not a literal array, so it must be skipped rather than `.any?`'d.
    klass = Class.new do
      include Axn
      expects :channel, inclusion: { in: :valid_channels }
    end
    expect do
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:channel]).not_to have_key(:enum)
    end.not_to raise_error
  end
end
