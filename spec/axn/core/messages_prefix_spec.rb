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

RSpec.describe "Axn error_prefix on fail!" do
  subject(:error) { action.call.error }

  context "fail! prefixed by the base by default" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("email taken")
      end
    end
    it { is_expected.to eq("Couldn't sync user: email taken") }
  end

  context "fail! opting out with prefixed: false" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("Account is locked.", prefixed: false)
      end
    end
    it { is_expected.to eq("Account is locked.") }
  end

  context "fail! with no base declared" do
    let(:action) do
      build_axn { def call = fail!("email taken") }
    end
    it { is_expected.to eq("email taken") }
  end
end

RSpec.describe "Axn success prefixing parity" do
  subject(:success) { action.call.success }

  context "done! prefixed by base success" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("from cache")
      end
    end
    it { is_expected.to eq("User synced: from cache") }
  end

  context "done! opting out" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("Already current.", prefixed: false)
      end
    end
    it { is_expected.to eq("Already current.") }
  end

  context "conditional success reason prefixed" do
    let(:action) do
      build_axn do
        expects :n, type: Integer
        success "Computed"
        success "via fast path", if: -> { n.zero? }
        def call = nil
      end
    end
    it { expect(action.call(n: 0).success).to eq("Computed: via fast path") }
  end
end

RSpec.describe "Nested call! parity" do
  it "re-raises the inner's original exception (no wrapping, no source)" do
    inner = build_axn { def call = raise ArgumentError, "boom" }
    outer = build_axn do
      expects :inner
      def call = inner.call!
    end
    expect { outer.call!(inner:) }.to raise_error(ArgumentError, "boom")
  end

  it "composes a child's error via the explicit call + fail! idiom" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      def call
        r = inner.call
        fail!("charging: #{r.error}") unless r.ok?
      end
    end
    expect(outer.call(inner:).error).to eq("Onboarding failed: charging: Charge failed: card declined")
  end
end

RSpec.describe "removed error options" do
  it "rejects from:" do
    expect { build_axn { error "x", from: Object } }.to raise_error(ArgumentError, /from: is no longer supported/)
  end

  it "rejects per-message prefix:" do
    expect { build_axn { error "x", prefix: "P: " } }.to raise_error(ArgumentError, /prefix: is no longer supported/)
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
