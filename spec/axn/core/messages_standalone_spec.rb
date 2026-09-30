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

RSpec.describe "Axn error block that interpolates the exception message" do
  subject(:error) { action.call.error }

  def with_header(header_declaration, body)
    build_axn do
      instance_exec(&header_declaration)
      define_method(:call, &body)
    end
  end

  let(:interpolating_header) { proc { error { |e| "W: #{e.message}" } } }
  let(:plain_header) { proc { error "W" } }

  # The block is the header and the reason is joined onto it, so a header that repeats the reason
  # prints it twice, and with no reason to join it puts the raw exception text in `result.error`.
  # docs/usage/writing.md documents both; these pin the claims it makes.
  describe "a header block reading e.message" do
    it "repeats a fail! reason" do
      expect(with_header(interpolating_header, -> { fail!("boom") }).call.error).to eq("W: boom: boom")
    end

    it "repeats a fails_on reason" do
      action = build_axn do
        error { |e| "W: #{e.message}" }
        fails_on ArgumentError, &:message
        def call = raise ArgumentError, "bad"
      end
      expect(action.call.error).to eq("W: bad: bad")
    end

    it "repeats a bubbled child's presentation" do
      child = build_axn { def call = fail!("child") }
      action = build_axn do
        error { |e| "W: #{e.message}" }
        define_method(:call) { child.call! }
      end
      expect(action.call.error).to eq("W: child: child")
    end

    it "prints the raw text beside an authored conditional reason" do
      action = build_axn do
        error { |e| "W: #{e.message}" }
        error "friendly", if: ArgumentError
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("W: raw: friendly")
    end

    it "repeats a conditional reason that is the exception's own message" do
      action = build_axn do
        error { |e| "W: #{e.message}" }
        error(if: ArgumentError, &:message)
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("W: raw: raw")
    end

    it "leaks the raw text of an unexpected exception" do
      expect(with_header(interpolating_header, -> { raise "kaboom" }).call.error).to eq("W: kaboom")
    end
  end

  describe "a header that does not repeat the reason" do
    it "attaches a fail! reason once" do
      expect(with_header(plain_header, -> { fail!("boom") }).call.error).to eq("W: boom")
    end

    it "attaches a bubbled child's presentation once" do
      child = build_axn { def call = fail!("child") }
      action = build_axn do
        error "W"
        define_method(:call) { child.call! }
      end
      expect(action.call.error).to eq("W: child")
    end

    it "keeps an unexpected exception's message out of result.error" do
      expect(with_header(plain_header, -> { raise "kaboom" }).call.error).to eq("W")
    end

    it "keeps a validation failure's message out of result.error" do
      action = build_axn do
        error "W"
        expects :n, type: String
        def call = nil
      end
      expect(action.call.error).to eq("W")
    end
  end

  describe "a per-class message opt-in" do
    let(:action) do
      build_axn do
        error "W"
        error(if: ArgumentError, &:message)
        def call = raise(ArgumentError, "x")
      end
    end

    it "surfaces the opted-in class's message under the header" do
      expect(error).to eq("W: x")
    end

    it "still keeps every other exception's message out" do
      other = build_axn do
        error "W"
        error(if: ArgumentError, &:message)
        def call = raise("kaboom")
      end
      expect(other.call.error).to eq("W")
    end
  end

  describe "the documented always-on detail example (standalone: false with authored text)" do
    let(:raised) { RuntimeError }
    let(:action_class) do
      exception_class = raised
      build_axn do
        error "Couldn't sync user", join: " — "
        error "check the vendor status page", standalone: false
        error "vendor not found", if: ArgumentError, standalone: true
        define_method(:call) { raise exception_class, "lookup failed" }
      end
    end

    context "when the standalone reason's class is raised" do
      let(:raised) { ArgumentError }

      it "lets the standalone reason win" do
        expect(action_class.call.error).to eq("vendor not found")
      end
    end

    it "attaches the authored detail to the base for any other exception, never its raw message" do
      expect(action_class.call.error).to eq("Couldn't sync user — check the vendor status page")
    end
  end

  describe "the documented Customizing messages example" do
    let(:action) do
      build_axn do
        expects :name, type: String
        exposes :meaning_of_life
        success { "Revealed to #{name}: #{result.meaning_of_life}" }
        error "No secret of life for you"

        def call
          fail! "Douglas already knows the meaning" if name == "Doug"

          expose meaning_of_life: "Hello #{name}, the meaning of life is 42"
        end
      end
    end

    it "matches the outputs shown in docs/usage/writing.md" do
      expect(action.call.error).to eq("No secret of life for you")
      expect(action.call(name: "Doug").error).to eq("No secret of life for you: Douglas already knows the meaning")
      expect(action.call(name: "Adams").success).to eq("Revealed to Adams: Hello Adams, the meaning of life is 42")
      expect(action.call(name: "Adams").meaning_of_life).to eq("Hello Adams, the meaning of life is 42")
    end
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

  it "raises at declaration when join: false is given (false is not nil, String, or callable)" do
    expect do
      build_axn { error "Base", join: false }
    end.to raise_error(ArgumentError, /join: must be a String or a callable/)
  end
end

RSpec.describe "removed error options" do
  it "rejects from: as an unknown option (the kwarg is gone, not tombstoned)" do
    expect { build_axn { error "x", from: Object } }.to raise_error(ArgumentError, %r{Unknown :from option for error/success message})
  end

  it "rejects per-message prefix: as an unknown option" do
    expect { build_axn { error "x", prefix: "P: " } }.to raise_error(ArgumentError, %r{Unknown :prefix option for error/success message})
  end

  # The DSL guard alone leaves the direct/Factory descriptor path able to silently swallow unknown
  # options; MessageDescriptor.build must reject them the same way (never a silent ignore).
  describe "directly via MessageDescriptor.build (the Factory/prebuilt path)" do
    let(:descriptor) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

    it "rejects from: as an unknown option" do
      expect { descriptor.build(handler: "x", from: Object) }.to raise_error(ArgumentError, %r{Unknown :from option for error/success message})
    end

    it "rejects prefix: as an unknown option" do
      expect { descriptor.build(handler: "x", prefix: "P: ") }.to raise_error(ArgumentError, %r{Unknown :prefix option for error/success message})
    end

    it "rejects an otherwise-unknown option rather than silently ignoring it" do
      expect { descriptor.build(handler: "x", bogus: 1) }.to raise_error(ArgumentError, /Unknown :bogus option/)
    end
  end
end

RSpec.describe "error/success message grammar" do
  # Until now `MessageDescriptor.build` validated `join:` and `standalone:` but never the message
  # itself -- `error 42` / `success Object.new` declared cleanly and put the literal value on
  # `result.error`, violating its documented String contract. This is the same declaration-time
  # grammar `expects ..., user_facing:` already enforces (`Contract.validate_user_facing!`), applied
  # to the mirror layer that never got it. It is also what makes the `fails_on` classes/message
  # mis-bind (see fails_on_spec.rb) silent: a mis-bound Class landed here unchecked.
  %i[error success].each do |dsl|
    describe "`#{dsl}`" do
      it "rejects an Integer literal" do
        expect do
          build_axn { public_send(dsl, 42) }
        end.to raise_error(ArgumentError, /message must be a String, a Symbol, or a callable.*class Integer/)
      end

      it "rejects an arbitrary Object" do
        expect do
          build_axn { public_send(dsl, Object.new) }
        end.to raise_error(ArgumentError, /message must be a String, a Symbol, or a callable.*class Object/)
      end

      it "accepts a String" do
        expect { build_axn { public_send(dsl, "ok") } }.not_to raise_error
      end

      it "accepts a Symbol naming an action method" do
        expect { build_axn { public_send(dsl, :some_method) } }.not_to raise_error
      end

      it "accepts a Proc" do
        expect { build_axn { public_send(dsl, -> { "ok" }) } }.not_to raise_error
      end

      it "accepts a block" do
        expect { build_axn { public_send(dsl) { "ok" } } }.not_to raise_error
      end

      # Codex review, PR #272: an explicit `false` positional alongside a block used to be silently
      # accepted -- `false` reads as falsy in `_add_message`'s OWN presence/conflict checks, so
      # neither "both given" nor "neither given" fired, and `_build_entry` preferred the block,
      # dropping the invalid `false` with no complaint at all (the grammar guard added above never
      # even ran). `nil` alongside a block is unaffected -- still means "no message", same as
      # omitting the positional entirely.
      it "rejects an explicit false positional alongside a block rather than silently preferring the block" do
        expect do
          build_axn { public_send(dsl, false) { "ok" } }
        end.to raise_error(ArgumentError, /Provide either a message or a block, not both/)
      end

      it "still prefers the block when the positional is explicitly nil" do
        expect { build_axn { public_send(dsl, nil) { "ok" } } }.not_to raise_error
      end
    end
  end

  describe "directly via MessageDescriptor.build (the Factory/prebuilt path)" do
    let(:descriptor) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

    it "rejects a non-String/Symbol/callable handler" do
      expect { descriptor.build(handler: 42) }.to raise_error(ArgumentError, /message must be a String, a Symbol, or a callable/)
    end

    it "refuses to let a hostile respond_to? replace the verdict with its own exception" do
      hostile = Object.new
      def hostile.respond_to?(*) = raise "boom"

      expect { descriptor.build(handler: hostile) }.to raise_error(ArgumentError, /message must be a String, a Symbol, or a callable/)
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
