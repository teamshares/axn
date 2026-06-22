# frozen_string_literal: true

require "bigdecimal"
require "date"
require "tempfile"

RSpec.describe Axn::Internal::AsyncSerialization do
  describe "ActiveJob path (ActiveJob available)" do
    it "is using the ActiveJob branch in this suite" do
      expect(described_class._active_job_available?).to be(true)
    end

    it "round-trips rich types losslessly" do
      input = {
        sym: :active,
        date: Date.new(2026, 6, 22),
        time: Time.at(1_700_000_000),
        money: BigDecimal("1.5"),
        nested: { a: 1, "b" => [Date.new(2026, 1, 1), :x] },
      }
      output = described_class.deserialize(described_class.serialize(input))
      expect(output).to eq(input)
      expect(output[:sym]).to be_a(Symbol)
      expect(output[:date]).to be_a(Date)
      expect(output[:money]).to be_a(BigDecimal)
    end

    it "raises a field-aware UnserializableArgument for a Tempfile" do
      expect { described_class.serialize(doc: Tempfile.new("x")) }
        .to raise_error(Axn::Async::UnserializableArgument, /`doc`.*Tempfile/m)
    end
  end
end
