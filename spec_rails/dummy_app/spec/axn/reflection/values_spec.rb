# frozen_string_literal: true

# Rails loads ActiveSupport's Object#as_json globally, so every object responds to as_json. These
# specs guard that serialize_value still prefers a value object's own to_h over that generic dump.
RSpec.describe Axn::Reflection::Values do
  it "sanity: Rails has added the generic Object#as_json" do
    expect(Object.new).to respond_to(:as_json)
  end

  it "serializes a value object via its own to_h, not ActiveSupport's generic Object#as_json ivar dump" do
    dto = Class.new do
      def initialize = @internal_secret = "leak"
      def to_h = { label: "public" }
    end.new

    expect(described_class.serialize_value(dto)).to eq("label" => "public")
  end

  it "still follows a value object's OWN as_json when it defines one" do
    dto = Class.new do
      def as_json(*) = { via: "as_json" }
      def to_h = { via: "to_h" }
    end.new

    expect(described_class.serialize_value(dto)).to eq("via" => "as_json")
  end

  # A value with neither its own as_json nor a to_h declares no shape at all. Only in Rails does it reach
  # the as_json branch — the generic Object#as_json is the sole reason it responds — so this is where the
  # reject_opaque verdict on that shape is observable.
  describe "a value whose only as_json is ActiveSupport's generic Object#as_json" do
    let(:undeclared) do
      Class.new do
        def initialize
          @name = "widget"
          @secret = "tok"
        end
      end.new
    end

    it "renders ActiveSupport's instance-variable dump by default" do
      expect(described_class.serialize_value(undeclared, path: "owner")).to eq("name" => "widget", "secret" => "tok")
    end

    it "raises under reject_opaque:, since the dump leaks internals and isn't the declared schema's shape" do
      expect { described_class.serialize_value(undeclared, path: "owner", reject_opaque: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          %r{`owner`.*declares no JSON projection of its own.*give the value its own `as_json`/`to_h`}m,
        )
    end

    it "leaves an ActiveRecord model, which has its own as_json, serializing under reject_opaque:" do
      user = User.new(name: "Ada")

      expect(user.method(:as_json).owner).not_to eq(Object)
      expect(described_class.serialize_value(user, path: "user", reject_opaque: true)).to include("name" => "Ada")
    end

    it "leaves a value object with a to_h serializing under reject_opaque:" do
      dto = Class.new do
        def initialize = @internal_secret = "leak"
        def to_h = { label: "public" }
      end.new

      expect(described_class.serialize_value(dto, path: "dto", reject_opaque: true)).to eq("label" => "public")
    end

    it "checks the same shape at depth, naming the nested path" do
      expect { described_class.serialize_value({ rows: [undeclared] }, path: "out", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\]`/)
    end
  end
end
