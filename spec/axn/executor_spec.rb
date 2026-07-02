# frozen_string_literal: true

RSpec.describe Axn::Executor do
  describe "#resolve_inbound_facets" do
    # Build a throwaway (non-run) instance and resolve, mirroring the enqueue path.
    def resolve(klass, sources: %i[tag dimension], **inputs)
      instance = klass.send(:new, **inputs)
      described_class.new(instance).resolve_inbound_facets(sources)
    end

    it "resolves input-derived tags and dimensions" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq(company_id: 42, plan: "pro")
    end

    it "filters by requested sources" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, sources: %i[dimension], company_id: 42)).to eq(plan: "pro")
    end

    it "applies inbound preprocess and defaults before resolving" do
      klass = build_axn do
        expects :name, preprocess: lambda(&:upcase)
        expects :region, default: "us5"
        tag(:name) { name }
        tag(:region) { region }
        def call; end
      end
      expect(resolve(klass, name: "acme")).to eq(name: "ACME", region: "us5")
    end

    it "omits result-derived facets (no run has happened)" do
      klass = build_axn do
        expects :company_id
        exposes :charge_id
        tag(:company_id) { company_id }
        dimension(:charge) { result.charge_id } # nil before any run → omitted
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq(company_id: 42)
    end

    it "swallows a failure in the inbound pass and still resolves what it can" do
      klass = build_axn do
        expects :name, preprocess: ->(_v) { raise "boom" }
        tag(:region) { "us5" }
        tag(:name) { name }
        def call; end
      end
      expect(resolve(klass, name: "acme")).to eq(region: "us5", name: "acme")
    end

    it "omits a facet whose resolver raises, keeping the rest" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        tag(:boom) { raise "nope" }
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq(company_id: 42)
    end
  end
end
