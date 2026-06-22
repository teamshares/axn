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
end
