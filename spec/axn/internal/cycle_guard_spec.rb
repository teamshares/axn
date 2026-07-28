# frozen_string_literal: true

require "json" # not loaded by default in the non-Rails suite; the placeholder's JSON-safety is asserted below

RSpec.describe Axn::Internal::CycleGuard do
  # For handing data to code with no cycle guard of its own — ActiveSupport::ParameterFilter, which axn
  # cannot fix in place.
  describe ".decycle" do
    it "replaces a self-referential Array with the placeholder, leaving everything else intact" do
      array = [1, { keep: "me" }]
      array << array

      expect(described_class.decycle(array)).to eq([1, { keep: "me" }, "[...]"])
    end

    it "replaces a self-referential Hash with the placeholder" do
      hash = { keep: "me" }
      hash[:self] = hash

      expect(described_class.decycle(hash)).to eq({ keep: "me", self: "{...}" })
    end

    it "copies rather than mutating the caller's structure" do
      array = [1]
      array << array

      described_class.decycle(array)

      expect(array.last).to be(array)
    end

    it "returns acyclic values unchanged, at any depth" do
      value = { a: [1, { b: [2, 3] }], c: "d" }

      expect(described_class.decycle(value)).to eq(value)
    end

    it "leaves a container merely repeated among siblings intact" do
      shared = [1]

      expect(described_class.decycle({ a: shared, b: shared })).to eq({ a: [1], b: [1] })
    end

    # The placeholder must read like a guarded walk's (`[...]`, not `"\"[...]\""` once a formatter
    # inspects it) while still being an ordinary String to ParameterFilter and any JSON serializer.
    it "uses a placeholder that inspects bare but is still a String" do
      placeholder = described_class::ARRAY_PLACEHOLDER

      expect(placeholder).to be_a(String)
      expect(placeholder).to eq("[...]")
      expect(placeholder.inspect).to eq("[...]")
      expect({ a: [placeholder] }.to_json).to eq('{"a":["[...]"]}')
    end
  end

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
