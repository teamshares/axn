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

  context "explicit empty delimiter (join with no separator)" do
    let(:action) do
      build_axn do
        error "Failed", delimiter: ""
        error "reason", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Failedreason") }
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

  context "prebuilt conditional descriptor is prefixed by the base (like the DSL)" do
    let(:action) do
      prebuilt = Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "invalid", if: ArgumentError)
      build_axn do
        error "Base"
        error prebuilt # closure-captured
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Base: invalid") }
  end

  context "an unconditional dynamic message is a headline by default (handler kind is irrelevant)" do
    # A block/symbol with no condition is a headline just like a literal — the most-recently
    # declared headline wins, so this replaces the earlier "Import failed" rather than prefixing it.
    let(:action) do
      build_axn do
        error "Import failed"
        error(&:message)
        def call = raise "raw boom"
      end
    end
    it { is_expected.to eq("raw boom") }
  end

  context "an unconditional dynamic message is prefixed only when opted in with prefixed: true" do
    let(:action) do
      build_axn do
        error "Import failed"
        error(prefixed: true, &:message)
        def call = raise "raw boom"
      end
    end
    it { is_expected.to eq("Import failed: raw boom") }
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

  context "delimiter comes from the headline that actually resolved, not a blank newer one" do
    # The newest headline is a block that resolves blank but carries `delimiter: ""`. base_message
    # falls back to the earlier "Base" headline, so the delimiter must come from "Base" (default
    # ": "), not the blank block — otherwise we'd render "Basedetail".
    let(:action) do
      build_axn do
        error "Base"
        error(delimiter: "") { "" }
        error "detail", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Base: detail") }
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
end

RSpec.describe "explicit call + fail! child-error composition" do
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

RSpec.describe "prefixed: false is scoped to the originating action" do
  it "honors prefixed: false at the action's own level (local opt-out)" do
    action = build_axn do
      error "Child base"
      def call = fail!("card declined", prefixed: false)
    end
    expect(action.call.error).to eq("card declined") # the action's own base is not applied
  end

  it "still applies the PARENT's base to a bubbled child fail!(prefixed: false) via call!" do
    stub_const("OptOutChild", build_axn { def call = fail!("card declined", prefixed: false) })
    parent = build_axn do
      error "Charging failed"
      def call = OptOutChild.call!
    end
    # The child's local opt-out does not disable the caller's base prefix.
    expect(parent.call.error).to eq("Charging failed: card declined")
  end
end

RSpec.describe "removed error options" do
  it "rejects from:" do
    expect { build_axn { error "x", from: Object } }.to raise_error(ArgumentError, /from: is no longer supported/)
  end

  it "rejects per-message prefix:" do
    expect { build_axn { error "x", prefix: "P: " } }.to raise_error(ArgumentError, /prefix: is no longer supported/)
  end

  # The DSL guard alone leaves the direct/Factory descriptor path able to silently swallow removed
  # options; MessageDescriptor.build must reject them with the same hint (and reject unknown options too).
  describe "directly via MessageDescriptor.build (the Factory/prebuilt path)" do
    let(:descriptor) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

    it "rejects from: with the migration hint" do
      expect { descriptor.build(handler: "x", from: Object) }.to raise_error(ArgumentError, /from: is no longer supported/)
    end

    it "rejects prefix: with the migration hint" do
      expect { descriptor.build(handler: "x", prefix: "P: ") }.to raise_error(ArgumentError, /prefix: is no longer supported/)
    end

    it "rejects an otherwise-unknown option rather than silently ignoring it" do
      expect { descriptor.build(handler: "x", bogus: 1) }.to raise_error(ArgumentError, /Unknown :bogus option/)
    end
  end
end

RSpec.describe "Axn error_prefix DSL" do
  describe "declaration validation" do
    it "allows prefixed: true on an unconditional message (promotes the headline to a prefixed reason)" do
      expect do
        build_axn { error "Headline", prefixed: true }
      end.not_to raise_error
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
      end.to raise_error(ArgumentError, /delimiter: only applies to the base/)
    end

    it "raises when delimiter: is given on a conditional reason that opted out with prefixed: false" do
      # Still a reason (conditional), not the base — so delimiter: must be rejected, not ignored.
      expect do
        build_axn { error "x", if: ArgumentError, prefixed: false, delimiter: " - " }
      end.to raise_error(ArgumentError, /delimiter: only applies to the base/)
    end

    it "allows delimiter: on a base error (an unconditional headline)" do
      expect do
        build_axn { error "Headline", delimiter: " - " }
      end.not_to raise_error
    end

    it "raises when delimiter: is combined with prefixed: true (which makes it a reason, not the base)" do
      expect do
        build_axn { error "x", delimiter: " - ", prefixed: true }
      end.to raise_error(ArgumentError, "delimiter: only applies to the base (an unprefixed headline)")
    end

    # The direct/Factory `MessageDescriptor.build` path (no DSL) must enforce the same validation,
    # rather than silently ignoring an option that resolution never reads.
    describe "direct MessageDescriptor.build path" do
      let(:described) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

      it "raises when delimiter: is given on a conditional reason" do
        expect do
          described.build(handler: "x", if: ArgumentError, delimiter: " - ")
        end.to raise_error(ArgumentError, /delimiter: only applies to the base/)
      end

      it "allows prefixed: true on an unconditional headline (promotes it to a prefixed reason)" do
        expect { described.build(handler: "Headline", prefixed: true) }.not_to raise_error
      end

      it "allows delimiter: on a base (unconditional headline) descriptor" do
        expect { described.build(handler: "Headline", delimiter: " - ") }.not_to raise_error
      end
    end
  end
end
