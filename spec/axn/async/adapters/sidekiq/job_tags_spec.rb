# frozen_string_literal: true

require "axn/async/adapters/sidekiq"

RSpec.describe Axn::Async::Adapters::Sidekiq do
  describe ".job_tags_for" do
    def format(facets) = described_class.job_tags_for(facets)

    it "formats scalar facets as name:value" do
      expect(format(company_id: 42, plan: "pro")).to eq(["company_id:42", "plan:pro"])
    end

    it "fans out an array value to one tag per element" do
      expect(format(plan: %w[trial paid])).to eq(["plan:trial", "plan:paid"])
    end

    it "stringifies boolean and numeric values" do
      expect(format(active: true, count: 3)).to eq(["active:true", "count:3"])
    end

    it "returns [] for an empty map" do
      expect(format({})).to eq([])
    end
  end
end
