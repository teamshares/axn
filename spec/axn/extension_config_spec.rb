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

  describe "the reserved core DSL option names" do
    let(:reserved) { Axn::Core::Contract.reserved_field_option_names }

    it "is a frozen Set" do
      expect(reserved).to be_a(Set)
      expect(reserved).to be_frozen
    end

    # One name per source the set unions, so a source silently dropping out of the derivation fails
    # here rather than reopening the hole it covered. `:method_call` is the canary for the signature
    # reflection specifically — it is an `expects` kwarg and appears in none of the three constants.
    it "draws from every source it is derived from" do
      expect(reserved).to include(:presence)    # KNOWN_VALIDATION_KEYS
      expect(reserved).to include(:allow_blank) # ActiveModel's shared validation options
      expect(reserved).to include(:method_call) # an `expects` kwarg, present in no constant
      expect(reserved).to include(:user_facing) # SHAPE_MEMBER_FIELD_OPTIONS
    end

    # The keys Ruby binds as kwargs before `**` collects them cannot be misrouted today, but the set is
    # scoped to what the DSL OWNS rather than to what is currently reachable: registering one is silently
    # inert for the extension, and a kwarg that later moves into the splat would otherwise reopen the hole.
    it "covers the kwargs that are bound before the splat, not only the misroutable keys" do
      expect(reserved).to include(:optional, :default, :sensitive, :as, :prefix)
    end

    it "does not reserve :description, the metadata key axn registers itself" do
      expect(reserved).not_to include(:description)
      expect(Axn::Extensions.config.registered_field_metadata_keys).to include(:description)
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
