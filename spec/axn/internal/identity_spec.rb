# frozen_string_literal: true

RSpec.describe Axn::Internal::Identity do
  describe ".utf8_string" do
    # One primitive, two fallbacks: this one scrubs so the text always renders. These are the outputs the
    # method had before the byte check moved into `Internal::Text`, pinned input by input so a future change
    # to the primitive cannot move them silently.
    {
      "ASCII" => %w[plain plain],
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
  end
end
