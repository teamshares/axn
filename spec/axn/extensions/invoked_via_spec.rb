# frozen_string_literal: true

RSpec.describe Axn::Extensions::InvokedVia do
  describe ".with" do
    it "delegates to Internal::CurrentEntryPoint, coerced through Core::Tagging.coerce first" do
      seen = nil
      described_class.with(:webhooks) { seen = Axn::Internal::CurrentEntryPoint.current }
      # A Symbol stringifies — same coercion any resolved facet value goes through.
      expect(seen).to eq("webhooks")
    end

    it "restores the previous value after the block" do
      described_class.with(:webhooks) {}
      expect(Axn::Internal::CurrentEntryPoint.current).to be_nil
    end

    it "returns the block's value" do
      expect(described_class.with(:webhooks) { 7 }).to eq(7)
    end

    it "does not raise when coercion fails — the block still runs, unstamped" do
      hostile = Object.new
      hostile.define_singleton_method(:to_s) { raise "boom" }
      seen = :unset
      expect { described_class.with(hostile) { seen = Axn::Internal::CurrentEntryPoint.current } }.not_to raise_error
      expect(seen).to be_nil
    end
  end
end
