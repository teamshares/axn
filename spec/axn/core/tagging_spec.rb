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

    it "accepts a literal value" do
      action = build_axn { tag :region, "us5" }
      expect(action._tags[:region].resolver).to eq("us5")
    end

    it "symbolizes string names" do
      action = build_axn { tag "company_id", -> { 1 } }
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

    it "defaults a facet to the input phase" do
      action = build_axn { tag :company_id, -> { 1 } }
      expect(action._tags[:company_id].result).to be(false)
    end

    it "marks a facet as result phase with result: true" do
      action = build_axn { tag :charged, -> { 1 }, result: true }
      expect(action._tags[:charged].result).to be(true)
    end

    it "accepts result: with the block form" do
      action = build_axn { tag(:charged, result: true) { 1 } }
      expect(action._tags[:charged].result).to be(true)
    end

    it "raises when positional args are not exactly a name/value pair" do
      expect { build_axn { tag :a, :b, :c } }.to raise_error(ArgumentError)
    end

    it "raises when given a bare name with no resolver" do
      expect { build_axn { tag :name } }.to raise_error(ArgumentError)
    end

    it "raises when given both a positional resolver and a block" do
      expect { build_axn { tag(:a, -> { 1 }) { 2 } } }.to raise_error(ArgumentError)
    end

    it "raises when given a block with no name" do
      expect { build_axn { tag {} } }.to raise_error(ArgumentError)
    end

    it "rejects the removed symbol-key hash form" do
      expect { build_axn { tag company_id: -> { 1 }, plan: -> { "pro" } } }.to raise_error(ArgumentError)
    end

    it "rejects the removed hashrocket hash form" do
      expect { build_axn { tag "company_id" => -> { 1 } } }.to raise_error(ArgumentError)
    end

    it "does not expose the parser as a public class method" do
      expect(build_axn { tag :a, -> { 1 } }).not_to respond_to(:_parse_facet)
    end
  end

  describe ".dimension declaration forms" do
    it "accepts a name + block" do
      action = build_axn { dimension(:x) { "value" } }
      expect(action._dimensions.keys).to eq([:x])
    end

    it "marks a dimension as result phase with result: true" do
      action = build_axn { dimension :total, -> { 1 }, result: true }
      expect(action._dimensions[:total].result).to be(true)
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

    it "stringifies non-finite floats (NaN / Infinity), which OpenTelemetry rejects" do
      expect(Axn::Core::Tagging.coerce(Float::INFINITY)).to eq("Infinity")
      expect(Axn::Core::Tagging.coerce(-Float::INFINITY)).to eq("-Infinity")
      expect(Axn::Core::Tagging.coerce(Float::NAN)).to eq("NaN")
    end

    it "stringifies integers outside the OTLP int64 range, passing in-range ones through" do
      expect(Axn::Core::Tagging.coerce(2**62)).to eq(2**62)
      expect(Axn::Core::Tagging.coerce(2**63)).to eq((2**63).to_s)
      expect(Axn::Core::Tagging.coerce(-(2**63) - 1)).to eq((-(2**63) - 1).to_s)
    end

    it "coerces each element of an array (consistent with scalar coercion)" do
      expect(Axn::Core::Tagging.coerce(%i[trial paid])).to eq(%w[trial paid])
      expect(Axn::Core::Tagging.coerce([1, 2])).to eq([1, 2])
    end

    it "preserves homogeneous string, numeric (mixed int/float), and boolean arrays (all OTel-legal)" do
      expect(Axn::Core::Tagging.coerce([1, 2.5])).to eq([1, 2.5])
      expect(Axn::Core::Tagging.coerce([true, false])).to eq([true, false])
      expect(Axn::Core::Tagging.coerce([true])).to eq([true])
    end

    it "stringifies genuinely mixed or nested arrays to keep them homogeneous and legal" do
      expect(Axn::Core::Tagging.coerce([1, :a])).to eq(%w[1 a])
      expect(Axn::Core::Tagging.coerce([1, true])).to eq(%w[1 true])
      expect(Axn::Core::Tagging.coerce([[1, 2], 3])).to eq(["[1, 2]", "3"])
    end
  end

  describe ".dup_facets" do
    it "returns an independent copy so mutation cannot leak back to the source" do
      source = { states: %w[trial paid], name: +"acme", count: 3 }
      copy = Axn::Core::Tagging.dup_facets(source)

      copy[:states] << "churned"
      copy[:states][0] << "!"
      copy[:name] << "!"

      expect(source[:states]).to eq(%w[trial paid])
      expect(source[:name]).to eq("acme")
      expect(copy[:count]).to eq(3)
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
      expect(child._tags[:a].resolver.call).to eq(99)
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
