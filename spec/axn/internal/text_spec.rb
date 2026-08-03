# frozen_string_literal: true

RSpec.describe Axn::Internal::Text do
  # A String SUBCLASS can override every method a byte check reads, and one whose `valid_encoding?`
  # returns true over bytes that aren't valid would defeat the check on precisely the value it exists to
  # catch — so every read here is a BOUND String method.
  let(:hostile) do
    Class.new(String) do
      def encoding = Encoding::UTF_8
      def valid_encoding? = true
      def ascii_only? = true
      def encode(*) = raise("encode explodes")
      def inspect = raise("inspect explodes")
    end
  end

  describe ".utf8_rendering" do
    it "hands back an ASCII string unchanged" do
      value = "plain"
      expect(described_class.utf8_rendering(value)).to be(value)
    end

    it "hands back valid multibyte UTF-8 unchanged" do
      expect(described_class.utf8_rendering("café")).to eq("café")
    end

    it "transcodes another encoding to its text" do
      expect(described_class.utf8_rendering("caf\xE9".dup.force_encoding("ISO-8859-1"))).to eq("café")
    end

    it "answers nil for bytes with no UTF-8 rendering" do
      expect(described_class.utf8_rendering("bad\xFF".dup.force_encoding("ASCII-8BIT"))).to be_nil
    end

    it "answers nil for a String tagged UTF-8 whose bytes are not valid" do
      expect(described_class.utf8_rendering("bad\xFF".dup.force_encoding("UTF-8"))).to be_nil
    end

    it "reads a subclass through bound String methods rather than its own" do
      value = hostile.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(described_class.utf8_rendering(value)).to be_nil
    end
  end

  describe ".renderable" do
    it "returns a frozen UTF-8 String for renderable bytes" do
      rendered = described_class.renderable("café")

      expect(rendered).to eq("café")
      expect(rendered.encoding).to eq(Encoding::UTF_8)
      expect(rendered).to be_frozen
    end

    it "escapes bytes with no UTF-8 rendering rather than dropping them" do
      rendered = described_class.renderable("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(rendered).to include('\xFF')
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end

    it "escapes through a bound inspect, so a subclass cannot raise instead" do
      value = hostile.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect(described_class.renderable(value)).to include('\xFF')
    end
  end
end
