# frozen_string_literal: true

RSpec.describe Axn::Internal::CurrentEntryPoint do
  describe ".current" do
    it "is nil outside any with block" do
      expect(described_class.current).to be_nil
    end
  end

  describe ".with" do
    it "sets .current for the duration of the block" do
      seen = nil
      described_class.with(:mcp) { seen = described_class.current }
      expect(seen).to eq(:mcp)
    end

    it "restores the previous value after the block returns" do
      described_class.with(:mcp) {}
      expect(described_class.current).to be_nil
    end

    it "restores the previous value even when the block raises" do
      expect do
        described_class.with(:mcp) { raise "boom" }
      end.to raise_error("boom")
      expect(described_class.current).to be_nil
    end

    it "nests: an inner with restores the OUTER value, not nil" do
      seen_inner = nil
      seen_after_inner = nil
      described_class.with(:mcp) do
        described_class.with(:ruby_llm) { seen_inner = described_class.current }
        seen_after_inner = described_class.current
      end
      expect(seen_inner).to eq(:ruby_llm)
      expect(seen_after_inner).to eq(:mcp)
    end

    it "returns the block's value" do
      expect(described_class.with(:mcp) { 42 }).to eq(42)
    end
  end

  describe "DIMENSION_NAME" do
    it "is :invoked_via" do
      expect(described_class::DIMENSION_NAME).to eq(:invoked_via)
    end
  end
end
