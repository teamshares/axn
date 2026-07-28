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

    # ActiveJob::Arguments walks the structure with no cycle guard, so a self-referential value blows its
    # stack instead of reporting unserializable. That IS bad input, so it takes the field-aware error —
    # but serialization also invokes CALLER code, and a stack overflow in there is that code's bug, so it
    # must keep its own class and backtrace rather than being relabelled as a malformed argument.
    describe "a stack overflow during serialization" do
      it "reports a genuinely cyclic argument as unserializable" do
        cyclic = [1]
        cyclic << cyclic

        expect { described_class.serialize(payload: cyclic) }
          .to raise_error(Axn::Async::UnserializableArgument, /`payload`.*Array/m)
      end

      it "reports a cycle nested below the top level too" do
        cyclic = {}
        cyclic["self"] = cyclic

        expect { described_class.serialize(payload: { a: [{ b: cyclic }] }) }
          .to raise_error(Axn::Async::UnserializableArgument, /`payload`/)
      end

      it "leaves a caller's own runaway recursion alone (its bug, not a bad argument)" do
        recursive = Class.new do
          include GlobalID::Identification
          def id = 1
          def to_global_id(*) = to_global_id
        end

        expect { described_class.serialize(payload: recursive.new) }.to raise_error(SystemStackError)
      end

      it "leaves it alone even when nested inside an acyclic container" do
        recursive = Class.new do
          include GlobalID::Identification
          def id = 1
          def to_global_id(*) = to_global_id
        end

        expect { described_class.serialize(payload: { wrap: [recursive.new] }) }.to raise_error(SystemStackError)
      end
    end

    it "raises a field-aware UnserializableArgument for a Tempfile" do
      expect { described_class.serialize(doc: Tempfile.new("x")) }
        .to raise_error(Axn::Async::UnserializableArgument, /`doc`.*Tempfile/m)
    end
  end
end
