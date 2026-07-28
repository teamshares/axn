# frozen_string_literal: true

RSpec.describe Axn::Internal::CycleGuard do
  describe ".guard" do
    it "yields a visited-set and returns the block's value when the container is new" do
      seen = nil
      result = described_class.guard([1], nil, on_cycle: "[...]") do |nested|
        seen = nested
        :walked
      end

      expect(result).to eq(:walked)
      expect(seen).to be_a(Hash)
    end

    it "returns on_cycle without yielding when the container is already open on the path" do
      array = [1]

      outer = described_class.guard(array, nil, on_cycle: "[...]") do |nested|
        described_class.guard(array, nested, on_cycle: "[...]") { raise "must not descend into an open container" }
      end

      expect(outer).to eq("[...]")
    end

    # Ruby renders `x = [1]; [x, x].inspect` as "[[1], [1]]" — only genuine ancestry is a cycle, so
    # membership is popped on the way out and a container repeated among siblings renders in full.
    it "pops membership on the way out so sibling repeats are not treated as cycles" do
      array = [1]
      descended = 0

      described_class.guard([array, array], nil, on_cycle: "[...]") do |nested|
        [array, array].each do
          described_class.guard(array, nested, on_cycle: "[...]") { descended += 1 }
        end
      end

      expect(descended).to eq(2)
    end

    it "pops membership even when the block raises" do
      array = [1]
      seen = {}.compare_by_identity

      expect { described_class.guard(array, seen, on_cycle: "[...]") { raise "boom" } }.to raise_error("boom")
      expect(seen).to be_empty
    end

    # Identity, never ==/hash: a cycle is the same OBJECT recurring, and two equal-but-distinct
    # containers (or one with a custom ==) must each be walked.
    it "keys on identity, not equality" do
      first = [1]
      second = [1]
      descended = 0

      described_class.guard(first, nil, on_cycle: "[...]") do |nested|
        described_class.guard(second, nested, on_cycle: "[...]") { descended += 1 }
      end

      expect(descended).to eq(1)
    end
  end
end
