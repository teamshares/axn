# frozen_string_literal: true

RSpec.describe Axn::Extensions::InvokedVia do
  describe ".with" do
    it "delegates to Internal::CurrentEntryPoint" do
      seen = nil
      described_class.with(:webhooks) { seen = Axn::Internal::CurrentEntryPoint.current }
      expect(seen).to eq(:webhooks)
    end

    it "restores the previous value after the block" do
      described_class.with(:webhooks) {}
      expect(Axn::Internal::CurrentEntryPoint.current).to be_nil
    end

    it "returns the block's value" do
      expect(described_class.with(:webhooks) { 7 }).to eq(7)
    end
  end
end
