# frozen_string_literal: true

RSpec.describe Axn::Core::Tagging do
  describe ".tag / .dimension declaration forms" do
    it "accepts a name + positional resolver" do
      action = build_axn { tag :company_id, -> { 1 } }
      expect(action._tags.keys).to eq([:company_id])
    end

    it "accepts a name + block" do
      action = build_axn { tag(:region) { "us5" } }
      expect(action._tags.keys).to eq([:region])
    end

    it "accepts a hash of many at once" do
      action = build_axn { tag company_id: -> { 1 }, plan: -> { "pro" } }
      expect(action._tags.keys).to eq(%i[company_id plan])
    end

    it "accepts a literal value" do
      action = build_axn { tag :region, "us5" }
      expect(action._tags[:region]).to eq("us5")
    end

    it "symbolizes string keys" do
      action = build_axn { tag "company_id" => -> { 1 } }
      expect(action._tags.keys).to eq([:company_id])
    end

    it "stores dimensions separately from tags" do
      action = build_axn do
        tag :company_id, -> { 1 }
        dimension :plan_tier, -> { "pro" }
      end
      expect(action._tags.keys).to eq([:company_id])
      expect(action._dimensions.keys).to eq([:plan_tier])
    end

    it "raises when positional args are not exactly a name/value pair" do
      expect { build_axn { tag :a, :b, :c } }.to raise_error(ArgumentError)
    end
  end

  describe "inheritance / mixin merge" do
    it "accumulates parent and subclass declarations, subclass overriding same key" do
      parent = build_axn { tag :a, -> { 1 } }
      child = Class.new(parent)
      child.tag :b, -> { 2 }
      child.tag :a, -> { 99 } # override
      expect(parent._tags.keys).to eq([:a]) # parent unchanged
      expect(child._tags.keys).to eq(%i[a b])
      expect(child._tags[:a].call).to eq(99)
    end

    it "accumulates declarations from an included module" do
      concern = Module.new do
        def self.included(base) = base.tag(:from_concern, -> { 1 })
      end
      action = build_axn { include concern }
      expect(action._tags.keys).to include(:from_concern)
    end
  end
end
