# frozen_string_literal: true

require "tempfile"
require "stringio"

RSpec.describe Axn::Internal::AsyncSerialization do
  describe Axn::Async::UnserializableArgument do
    it "names the field, the class, and a generic fix hint" do
      error = described_class.new(field: :widget, value: Object.new)
      expect(error).to be_a(ArgumentError)
      expect(error.message).to include("widget")
      expect(error.message).to include("Object")
      expect(error.message).to include("GlobalID-able")
    end

    it "gives an IO-specific hint for file-like values" do
      error = described_class.new(field: :doc, value: StringIO.new("x"))
      expect(error.message).to include("Persist it to ActiveStorage")
    end
  end

  describe "fallback path (ActiveJob unavailable)" do
    before { allow(described_class).to receive(:_active_job_available?).and_return(false) }

    it "passes JSON-native values through with stringified keys" do
      result = described_class.serialize(name: "World", age: 25, ok: true, tags: ["a", 1])
      expect(result).to eq("name" => "World", "age" => 25, "ok" => true, "tags" => ["a", 1])
    end

    it "serializes a GlobalID-able value via the _as_global_id suffix" do
      gid_able = Object.new
      def gid_able.to_global_id = "gid://app/User/1"
      result = described_class.serialize(user: gid_able)
      expect(result).to eq("user_as_global_id" => "gid://app/User/1")
    end

    it "raises a field-aware error for a Symbol (lossy stringification footgun)" do
      expect { described_class.serialize(status: :active) }
        .to raise_error(Axn::Async::UnserializableArgument, /`status`.*Symbol/m)
    end

    it "raises for a Tempfile with the IO hint" do
      require "tempfile"
      expect { described_class.serialize(doc: Tempfile.new("x")) }
        .to raise_error(Axn::Async::UnserializableArgument, /ActiveStorage/)
    end

    it "raises for Date/Time/Object (not round-trippable without ActiveJob)" do
      require "date"
      [Date.today, Time.now, Object.new].each do |value|
        expect { described_class.serialize(field: value) }
          .to raise_error(Axn::Async::UnserializableArgument)
      end
    end

    it "raises for a nested hash with non-string keys (the JSON round-trip would stringify them)" do
      expect { described_class.serialize(opts: { 1 => "one" }) }
        .to raise_error(Axn::Async::UnserializableArgument, /`opts`/)
    end

    it "accepts a nested hash with string keys" do
      expect(described_class.serialize(opts: { "k" => "v" })).to eq("opts" => { "k" => "v" })
    end

    it "deserializes plain values by symbolizing keys" do
      expect(described_class.deserialize("name" => "World", "age" => 25))
        .to eq(name: "World", age: 25)
    end
  end

  # Deserialization must be driven by the payload's own format markers, not the current
  # process's loaded constants — a job may be enqueued and performed in processes that
  # differ in whether ActiveJob is loaded.
  describe "format-aware deserialization" do
    it "decodes a fallback (_as_global_id) payload with GlobalIdSerialization even when ActiveJob is loaded" do
      allow(described_class).to receive(:_active_job_available?).and_return(true)
      payload = { "user_as_global_id" => "gid://app/User/1", "name" => "World" }
      expect(Axn::Internal::GlobalIdSerialization).to receive(:deserialize).with(payload).and_return(:decoded)
      expect(described_class.deserialize(payload)).to eq(:decoded)
    end

    it "decodes an ActiveJob-tagged payload with the ActiveJob decoder even when the process check says ActiveJob is absent" do
      allow(described_class).to receive(:_active_job_available?).and_return(false)
      payload = { "at" => { "_aj_serialized" => "ActiveJob::Serializers::TimeSerializer", "value" => "2026-01-01T00:00:00Z" } }
      expect(described_class).to receive(:_deserialize_via_active_job).with(payload).and_return(:decoded)
      expect(described_class.deserialize(payload)).to eq(:decoded)
    end

    it "detects ActiveJob tags nested inside arrays/hashes" do
      allow(described_class).to receive(:_active_job_available?).and_return(false)
      payload = { "items" => [{ "_aj_globalid" => "gid://app/User/1" }] }
      expect(described_class).to receive(:_deserialize_via_active_job).with(payload).and_return(:decoded)
      expect(described_class.deserialize(payload)).to eq(:decoded)
    end

    it "decodes a marker-free JSON-native payload by symbolizing keys without needing ActiveJob" do
      allow(described_class).to receive(:_active_job_available?).and_return(false)
      expect(described_class.deserialize("name" => "World", "age" => 25)).to eq(name: "World", age: 25)
    end
  end
end
