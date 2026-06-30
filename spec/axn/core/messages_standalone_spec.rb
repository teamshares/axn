# frozen_string_literal: true

RSpec.describe "Axn standalone message resolution" do
  subject(:error) { action.call.error }

  context "declared reason with a base (attached by default)" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: is invalid") }
  end

  context "reason opted out with standalone: true" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "Vendor not found", if: ArgumentError, standalone: true
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

  context "custom join on the base" do
    let(:action) do
      build_axn do
        error "Couldn't sync user", join: " — "
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user — is invalid") }
  end

  context "explicit empty join (no separator)" do
    let(:action) do
      build_axn do
        error "Failed", join: ""
        error "reason", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Failedreason") }
  end

  context "unconditional dynamic detail with a base (promoted via standalone: false)" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error(standalone: false, &:message)
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: boom") }
  end

  context "prebuilt conditional descriptor is attached to the base (like the DSL)" do
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
    # declared headline wins, so this replaces the earlier "Import failed" rather than attaching.
    let(:action) do
      build_axn do
        error "Import failed"
        error(&:message)
        def call = raise "raw boom"
      end
    end
    it { is_expected.to eq("raw boom") }
  end

  context "an unconditional dynamic message is attached only when promoted with standalone: false" do
    let(:action) do
      build_axn do
        error "Import failed"
        error(standalone: false, &:message)
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

  context "join comes from the headline that actually resolved, not a blank newer one" do
    # The newest headline is a block that resolves blank but carries `join: ""`. base_message
    # falls back to the earlier "Base" headline, so the join must come from "Base" (default
    # ": "), not the blank block — otherwise we'd render "Basedetail".
    let(:action) do
      build_axn do
        error "Base"
        error(join: "") { "" }
        error "detail", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Base: detail") }
  end

  context "a headline block that RAISES falls back to an earlier headline (and that headline's join)" do
    # The resolver promises "a headline whose block raises or returns blank falls back to an earlier
    # one" (message_resolver.rb). The blank case is covered above; this locks in the *raises* case,
    # which depends on body_for → Invoker.call rescuing internally.
    let(:action) do
      build_axn do
        error "Earlier base"
        error { raise "kaboom in headline" } # newest base raises → must be skipped
        error "detail", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Earlier base: detail") }
  end

  context "a declared-but-blank base still gates reasons as attached, then drops the empty base" do
    # The base IS declared (so the reason is treated as attached), but it resolves blank — so
    # with_base must drop the empty base rather than render a leading ": ".
    let(:action) do
      build_axn do
        error "" # base declared, resolves blank
        error "lonely reason", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("lonely reason") }
  end

  context "when multiple conditional reasons match, the most-recently-declared wins" do
    # Reasons are checked last-declared-first; both match an ArgumentError, so the later one wins.
    let(:action) do
      build_axn do
        error "Base"
        error "general", if: StandardError
        error "specific", if: ArgumentError # declared later → checked first → wins
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Base: specific") }
  end
end

RSpec.describe "Axn standalone on fail!" do
  subject(:error) { action.call.error }

  context "fail! attached to the base by default" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("email taken")
      end
    end
    it { is_expected.to eq("Couldn't sync user: email taken") }
  end

  context "fail! opting out with standalone: true" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("Account is locked.", standalone: true)
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

RSpec.describe "Axn standalone success parity" do
  subject(:success) { action.call.success }

  context "done! attached to base success by default" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("from cache")
      end
    end
    it { is_expected.to eq("User synced: from cache") }
  end

  context "done! opting out with standalone: true" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("Already current.", standalone: true)
      end
    end
    it { is_expected.to eq("Already current.") }
  end

  context "done!(nil, standalone: true) — no message, opt-out is moot, base resolves cleanly" do
    # The standalone:true flag must be recorded (not silently dropped), but with no message there is
    # no reason to attach, so the base headline resolves as usual.
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!(nil, standalone: true)
      end
    end
    it { is_expected.to eq("User synced") }
  end

  context "a child's done!(standalone: true) does not suppress the PARENT's own success base" do
    # The success opt-out is read from the context flag (not action-scoped) — safe because a child
    # early-completion never bubbles through the parent: call! swallows it and returns an ok result.
    let(:action) do
      child = build_axn { def call = done!("from cache", standalone: true) }
      build_axn do
        success "User synced"
        define_method(:call) { child.call! } # child early-completes ok; parent resolves its own base
      end
    end
    it { is_expected.to eq("User synced") }
  end

  context "success read before the action finalizes is not cached as a stale value" do
    # result.success/#message are memoized, but a Result is the same object during AND after the run.
    # Reading success while in-progress (ok? true, not finalized) must not freeze the pre-done! value.
    let(:action) do
      build_axn do
        success "User synced"
        before { result.message } # touch success while in-progress
        def call = done!("from cache")
      end
    end
    it { is_expected.to eq("User synced: from cache") }
  end

  context "conditional success reason attached" do
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

RSpec.describe "standalone: true is scoped to the originating action" do
  it "honors standalone: true at the action's own level (local opt-out)" do
    action = build_axn do
      error "Child base"
      def call = fail!("card declined", standalone: true)
    end
    expect(action.call.error).to eq("card declined") # the action's own base is not applied
  end

  it "still applies the PARENT's base to a bubbled child fail!(standalone: true) via call!" do
    stub_const("OptOutChild", build_axn { def call = fail!("card declined", standalone: true) })
    parent = build_axn do
      error "Charging failed"
      def call = OptOutChild.call!
    end
    # The child's local opt-out does not disable the caller's base attachment.
    expect(parent.call.error).to eq("Charging failed: card declined")
  end
end

RSpec.describe "bare: alias for standalone:" do
  it "bare: is an alias for standalone: (fail!)" do
    action = build_axn do
      error "Couldn't sync user"
      def call = fail!("card declined", bare: true)
    end
    expect(action.call.error).to eq("card declined")
  end

  it "bare: is an alias for standalone: (conditional error)" do
    action = build_axn do
      error "Couldn't sync user"
      error "Vendor not found", if: ArgumentError, bare: true
      def call = raise ArgumentError, "boom"
    end
    expect(action.call.error).to eq("Vendor not found")
  end
end

RSpec.describe "Axn join: Proc form" do
  it "wraps the reason (error)" do
    action = build_axn do
      error "Outer error", join: ->(base, reason) { "#{base} (#{reason})" }
      def call = fail!("inner error")
    end
    expect(action.call.error).to eq("Outer error (inner error)")
  end

  it "recases the reason's first letter (error)" do
    action = build_axn do
      error "Outer error", join: ->(base, reason) { "#{base}: #{reason[0].downcase}#{reason[1..]}" }
      def call = fail!("Inner error")
    end
    expect(action.call.error).to eq("Outer error: inner error")
  end

  it "applies for success/done! identically" do
    action = build_axn do
      success "User synced", join: ->(base, reason) { "#{base} (#{reason})" }
      def call = done!("from cache")
    end
    expect(action.call.success).to eq("User synced (from cache)")
  end

  it "raises at declaration when join: (Proc) is given on a reason" do
    expect do
      build_axn { error "x", if: ArgumentError, join: ->(b, r) { "#{b} #{r}" } }
    end.to raise_error(ArgumentError, /join: only applies to the base/)
  end

  it "raises at declaration when join: is neither a String nor callable" do
    expect do
      build_axn { error "Base", join: 5 }
    end.to raise_error(ArgumentError, /join: must be a String or a callable/)
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

RSpec.describe "Axn standalone: DSL" do
  describe "declaration validation" do
    it "allows standalone: false on an unconditional message (promotes the headline to an attached reason)" do
      expect do
        build_axn { error "Headline", standalone: false }
      end.not_to raise_error
    end

    it "allows standalone: false with a condition" do
      expect do
        build_axn { error "boom", if: ArgumentError, standalone: false }
      end.not_to raise_error
    end

    it "allows standalone: false with a dynamic (block) message and no condition" do
      expect do
        build_axn { error(standalone: false, &:message) }
      end.not_to raise_error
    end

    it "raises when join: is given on a conditional reason" do
      expect do
        build_axn { error "x", if: ArgumentError, join: " - " }
      end.to raise_error(ArgumentError, /join: only applies to the base/)
    end

    it "raises when join: is given on a conditional reason that opted out with standalone: true" do
      expect do
        build_axn { error "x", if: ArgumentError, standalone: true, join: " - " }
      end.to raise_error(ArgumentError, /join: only applies to the base/)
    end

    it "allows join: on a base error (an unconditional standalone headline)" do
      expect do
        build_axn { error "Headline", join: " - " }
      end.not_to raise_error
    end

    it "raises when join: is combined with standalone: false (which makes it a reason, not the base)" do
      expect do
        build_axn { error "x", join: " - ", standalone: false }
      end.to raise_error(ArgumentError, "join: only applies to the base (an unconditional headline)")
    end

    describe "direct MessageDescriptor.build path" do
      let(:described) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

      it "raises when join: is given on a conditional reason" do
        expect do
          described.build(handler: "x", if: ArgumentError, join: " - ")
        end.to raise_error(ArgumentError, /join: only applies to the base/)
      end

      it "allows standalone: false on an unconditional headline (promotes it to an attached reason)" do
        expect { described.build(handler: "Headline", standalone: false) }.not_to raise_error
      end

      it "allows join: on a base (unconditional standalone headline) descriptor" do
        expect { described.build(handler: "Headline", join: " - ") }.not_to raise_error
      end
    end
  end
end
