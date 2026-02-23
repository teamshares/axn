# frozen_string_literal: true

RSpec.describe Axn::ExtensionConfig do
  describe "Axn.extension_config" do
    it "returns an ExtensionConfig instance" do
      expect(Axn.extension_config).to be_a(Axn::ExtensionConfig)
    end

    it "returns the same instance on repeated calls" do
      expect(Axn.extension_config).to be(Axn.extension_config)
    end
  end

  describe "#registered_field_metadata_keys" do
    it "includes :description by default" do
      expect(Axn.extension_config.registered_field_metadata_keys).to include(:description)
    end

    it "returns a Set" do
      expect(Axn.extension_config.registered_field_metadata_keys).to be_a(Set)
    end
  end

  describe "#register_field_metadata_key" do
    let(:config) { Axn::ExtensionConfig.new }

    it "adds a single key" do
      config.register_field_metadata_key(:mcp_title)
      expect(config.registered_field_metadata_keys).to include(:mcp_title)
    end

    it "adds multiple keys" do
      config.register_field_metadata_key(:foo, :bar, :baz)
      expect(config.registered_field_metadata_keys).to include(:foo, :bar, :baz)
    end

    it "converts strings to symbols" do
      config.register_field_metadata_key("my_key")
      expect(config.registered_field_metadata_keys).to include(:my_key)
    end

    it "accumulates keys across multiple calls" do
      config.register_field_metadata_key(:first)
      config.register_field_metadata_key(:second)
      expect(config.registered_field_metadata_keys).to include(:first, :second)
    end

    it "handles duplicate keys gracefully (Set semantics)" do
      config.register_field_metadata_key(:duplicate)
      config.register_field_metadata_key(:duplicate)
      expect(config.registered_field_metadata_keys.count(:duplicate)).to eq(1)
    end
  end
end
