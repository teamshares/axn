# frozen_string_literal: true

RSpec.describe "Axn error_prefix resolution" do
  subject(:error) { action.call.error }

  context "declared reason with a base (prefixed by default)" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: is invalid") }
  end

  context "reason opted out with prefixed: false" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "Vendor not found", if: ArgumentError, prefixed: false
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Vendor not found") }
  end

  context "no base declared (gate closed)" do
    let(:action) do
      build_axn do
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("is invalid") }
  end

  context "custom delimiter on the base" do
    let(:action) do
      build_axn do
        error "Couldn't sync user", delimiter: " — "
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user — is invalid") }
  end

  context "unconditional dynamic detail with a base" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error(prefixed: true, &:message)
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: boom") }
  end

  context "no reason matches → base shown alone" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "is invalid", if: TypeError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user") }
  end
end

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
