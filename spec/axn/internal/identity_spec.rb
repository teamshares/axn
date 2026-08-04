# frozen_string_literal: true

RSpec.describe Axn::Internal::Identity do
  describe ".utf8_string" do
    # One primitive, two fallbacks: this one scrubs so the text always renders. These are the outputs the
    # method had before the byte check moved into `Internal::Text`, pinned input by input so a future change
    # to the primitive cannot move them silently.
    {
      "ASCII" => %w[plain plain],
      # ASCII bytes carrying a non-UTF-8 tag are the case the byte primitive's fast path answers with the
      # argument itself. They matter precisely because nothing downstream complains: ASCII-only bytes
      # concatenate with any encoding, so a wrong tag survives every join until one of them carries non-ASCII.
      "ASCII tagged BINARY" => ["plain".b, "plain"],
      "ASCII tagged US-ASCII" => ["plain".dup.force_encoding("US-ASCII"), "plain"],
      "ASCII tagged Latin-1" => ["plain".dup.force_encoding("ISO-8859-1"), "plain"],
      "valid multibyte UTF-8" => %w[café café],
      "transcodable Latin-1" => ["caf\xE9".dup.force_encoding("ISO-8859-1"), "café"],
      "UTF-16" => ["hi".encode("UTF-16"), "hi"],
      "empty" => ["", ""],
      "untranscodable binary" => ["bad\xFF".dup.force_encoding("ASCII-8BIT"), "bad�"],
      "UTF-8-tagged invalid bytes" => ["bad\xFF".dup.force_encoding("UTF-8"), "bad�"],
    }.each do |label, (input, expected)|
      it "renders #{label} as valid UTF-8" do
        rendered = described_class.utf8_string(input)

        expect(rendered).to eq(expected)
        expect(rendered.encoding).to eq(Encoding::UTF_8)
        expect(rendered.valid_encoding?).to be(true)
      end
    end

    it "answers with a plain String rather than a caller-owned subclass" do
      # The byte primitive's ASCII-only fast path answers with the argument itself, so without a copy this
      # hands a caller's own object back into axn's prose — where every later method call on it is caller code.
      subclass = Class.new(String)

      expect(described_class.utf8_string(subclass.new("plain")).class).to be(String)
    end
  end
end
