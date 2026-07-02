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

    it "raises when given a bare name with no resolver" do
      expect { build_axn { tag :name } }.to raise_error(ArgumentError)
    end

    it "raises when given the hash form together with a block" do
      expect { build_axn { tag(a: -> { 1 }) {} } }.to raise_error(ArgumentError)
    end

    it "raises when given a block with no name" do
      expect { build_axn { tag {} } }.to raise_error(ArgumentError)
    end

    it "does not expose _parse_facets as a public class method" do
      expect(build_axn { tag :a, -> { 1 } }).not_to respond_to(:_parse_facets)
    end
  end

  describe ".dimension declaration forms" do
    it "accepts a name + block" do
      action = build_axn { dimension(:x) { "value" } }
      expect(action._dimensions.keys).to eq([:x])
    end

    it "accepts a hash of many at once" do
      action = build_axn { dimension a: -> { 1 }, b: -> { 2 } }
      expect(action._dimensions.keys).to eq(%i[a b])
    end
  end

  describe ".coerce" do
    it "passes OpenTelemetry-legal scalars through unchanged" do
      expect(Axn::Core::Tagging.coerce("us5")).to eq("us5")
      expect(Axn::Core::Tagging.coerce(7)).to eq(7)
      expect(Axn::Core::Tagging.coerce(1.5)).to eq(1.5)
      expect(Axn::Core::Tagging.coerce(true)).to be(true)
    end

    it "stringifies a non-scalar value" do
      expect(Axn::Core::Tagging.coerce(:active)).to eq("active")
    end

    it "stringifies non-Integer/Float numerics (BigDecimal/Rational), which OpenTelemetry drops" do
      require "bigdecimal"
      expect(Axn::Core::Tagging.coerce(Rational(3, 2))).to eq("3/2")
      expect(Axn::Core::Tagging.coerce(BigDecimal("1.5"))).to be_a(String)
    end

    it "coerces each element of an array (consistent with scalar coercion)" do
      expect(Axn::Core::Tagging.coerce(%i[trial paid])).to eq(%w[trial paid])
      expect(Axn::Core::Tagging.coerce([1, 2])).to eq([1, 2])
    end

    it "stringifies a mixed-type array to keep it OpenTelemetry-legal" do
      expect(Axn::Core::Tagging.coerce([1, :a])).to eq(%w[1 a])
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
