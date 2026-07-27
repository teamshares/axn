# frozen_string_literal: true

RSpec.describe Axn::Extensions::Config do
  describe "Axn::Extensions.config" do
    it "returns a Config instance" do
      expect(Axn::Extensions.config).to be_a(Axn::Extensions::Config)
    end

    it "returns the same instance on repeated calls" do
      expect(Axn::Extensions.config).to be(Axn::Extensions.config)
    end
  end

  describe "#registered_field_metadata_keys" do
    it "includes :description by default" do
      expect(Axn::Extensions.config.registered_field_metadata_keys).to include(:description)
    end

    it "returns a Set" do
      expect(Axn::Extensions.config.registered_field_metadata_keys).to be_a(Set)
    end
  end

  describe "#register_field_metadata_key" do
    let(:config) { Axn::Extensions::Config.new }

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

RSpec.describe "Axn::Extensions::Config semantic hints" do
  after { Axn::Extensions.instance_variable_set(:@config, nil) }

  it "seeds the core semantic-hint vocabulary" do
    expect(Axn::Extensions.config.registered_semantic_hints).to include(:read_only, :idempotent, :destructive)
  end

  it "lets an adapter register additional vocabulary" do
    Axn::Extensions.config.register_semantic_hint(:open_world, :closed_world)
    expect(Axn::Extensions.config.registered_semantic_hints).to include(:open_world, :closed_world)
  end
end
