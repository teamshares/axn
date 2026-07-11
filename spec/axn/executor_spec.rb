# frozen_string_literal: true

RSpec.describe Axn::Executor do
  describe "#resolve_inbound_facets" do
    # Build a throwaway (non-run) instance and resolve, mirroring the enqueue path. Returns one
    # resolved map per enabled source (tags, then dimensions).
    def resolve(klass, sources: %i[tag dimension], **inputs)
      instance = klass.send(:new, **inputs)
      described_class.new(instance).resolve_inbound_facets(sources)
    end

    it "resolves input-derived tags and dimensions (one map per source)" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq([{ company_id: 42 }, { plan: "pro" }])
    end

    it "filters by requested sources" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, sources: %i[dimension], company_id: 42)).to eq([{ plan: "pro" }])
    end

    it "resolves against raw inputs — does not run preprocess or apply defaults" do
      klass = build_axn do
        expects :name, preprocess: lambda(&:upcase)
        expects :region, default: "us5"
        tag(:name) { name }
        tag(:region) { region }
        def call; end
      end
      # preprocess is NOT run (name stays raw "acme"); the default is NOT applied (region is nil,
      # so its facet is omitted) — enqueue facets mirror the raw payload, not the coerced run.
      # (Second map is the empty dimensions map — this action declares only tags.)
      expect(resolve(klass, name: "acme")).to eq([{ name: "acme" }, {}])
    end

    it "excludes result-phase facets (from: :result), keeping input-phase ones" do
      klass = build_axn do
        expects :company_id
        exposes :charge_id
        tag(:company_id) { company_id }
        dimension(:charge, from: :result) { result.charge_id } # result-phase → not resolved at enqueue
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq([{ company_id: 42 }, {}])
    end

    it "keeps a name declared as both a tag and a dimension in separate maps" do
      klass = build_axn do
        expects :account_id, :plan
        tag(:account) { account_id }
        dimension(:account) { plan }
        def call; end
      end
      # Both survive — the two maps are formatted independently downstream, so neither clobbers the other.
      expect(resolve(klass, account_id: 7, plan: "pro")).to eq([{ account: 7 }, { account: "pro" }])
    end

    it "omits a facet whose resolver raises, keeping the rest" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        tag(:boom) { raise "nope" }
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq([{ company_id: 42 }, {}])
    end
  end

  describe "#prepare_inbound_for_facets!" do
    # Build a throwaway (non-run) instance and prepare it, mirroring the async exhaustion/discard
    # report path (Axn::Async::ExceptionReporting), where an action is reconstructed from job args
    # and never executed.
    def prepare(klass, **inputs)
      instance = klass.send(:new, **inputs)
      described_class.new(instance).prepare_inbound_for_facets!
      instance
    end

    it "coerces a wire string before a facet reads the field" do
      klass = build_axn do
        expects :on, coerce: Date
        def call; end
      end
      instance = prepare(klass, on: "2026-07-08")
      expect(instance.on).to eq(Date.new(2026, 7, 8))
    end
  end
end
