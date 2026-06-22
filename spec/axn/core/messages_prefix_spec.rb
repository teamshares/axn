# frozen_string_literal: true

RSpec.describe "Axn error_prefix DSL" do
  describe "declaration validation" do
    it "raises when prefixed: true on a static unconditional error" do
      expect do
        build_axn { error "Headline", prefixed: true }
      end.to raise_error(ArgumentError, /prefixed: true requires a condition .* or a dynamic message/)
    end

    it "allows prefixed: true with a condition" do
      expect do
        build_axn { error "boom", if: ArgumentError, prefixed: true }
      end.not_to raise_error
    end

    it "allows prefixed: true with a dynamic (block) message and no condition" do
      expect do
        build_axn { error(prefixed: true, &:message) }
      end.not_to raise_error
    end

    it "raises when delimiter: is given on a conditional reason" do
      expect do
        build_axn { error "x", if: ArgumentError, delimiter: " - " }
      end.to raise_error(ArgumentError, /delimiter: only applies to a base error/)
    end

    it "allows delimiter: on a base error" do
      expect do
        build_axn { error "Headline", delimiter: " - " }
      end.not_to raise_error
    end
  end
end
