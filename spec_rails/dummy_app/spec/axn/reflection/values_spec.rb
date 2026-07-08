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
end
