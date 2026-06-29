# frozen_string_literal: true

RSpec.describe "Axn::Failure raw/presentation split" do
  it "exposes the raw fail! reason and falls back to it for #message" do
    f = Axn::Failure.new("email taken", action: nil)
    expect(f.raw_reason).to eq("email taken")
    expect(f.message).to eq("email taken")
  end

  it "returns the presentation from #message once stamped, leaving raw_reason intact" do
    f = Axn::Failure.new("email taken", action: nil)
    f.__present_as("Couldn't sync user: email taken")
    expect(f.message).to eq("Couldn't sync user: email taken")
    expect(f.raw_reason).to eq("email taken")
  end

  it "falls back to DEFAULT_MESSAGE when neither is present" do
    expect(Axn::Failure.new(nil, action: nil).message).to eq(Axn::Failure::DEFAULT_MESSAGE)
  end
end

RSpec.describe "Header aggregation across nested call!" do
  it "prefixes every level's base onto the leaf, outermost first" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    stub_const("Inner", inner)
    mid = build_axn do
      error "Onboarding failed"
      def call = Inner.call!
    end
    stub_const("Mid", mid)
    outer = build_axn do
      error "Signup failed"
      def call = Mid.call!
    end

    # two levels
    expect(mid.call.error).to eq("Onboarding failed: Charge failed: card declined")
    # three levels
    expect(outer.call.error).to eq("Signup failed: Onboarding failed: Charge failed: card declined")
  end

  it "passes the child's resolved presentation through a baseless ancestor unchanged" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      # no base declared
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Charge failed: card declined")
  end
end

RSpec.describe "Per-segment delimiters in aggregation" do
  it "uses each level's own delimiter for its own join" do
    inner = build_axn do
      error "C", delimiter: " | "
      def call = fail!("leaf")
    end
    stub_const("Inner", inner)
    mid = build_axn do
      error "B", delimiter: " > "
      def call = Inner.call!
    end
    stub_const("Mid", mid)
    outer = build_axn do
      error "A" # default ": "
      def call = Mid.call!
    end

    expect(outer.call.error).to eq("A: B > C | leaf")
  end
end

RSpec.describe "prefixed: false under aggregation" do
  it "suppresses the originating action's own base" do
    action = build_axn do
      error "Child base"
      def call = fail!("card declined", prefixed: false)
    end
    expect(action.call.error).to eq("card declined")
  end

  it "still lets an ancestor prefix its base onto a bubbled opt-out child" do
    stub_const("OptOutChild", build_axn { def call = fail!("card declined", prefixed: false) })
    parent = build_axn do
      error "Charging failed"
      def call = OptOutChild.call!
    end
    expect(parent.call.error).to eq("Charging failed: card declined")
  end
end

RSpec.describe "call! / #message parity (Axn::Failure)" do
  it "raises with #message equal to result.error at the top level" do
    action = build_axn do
      error "Couldn't sync user"
      def call = fail!("email taken")
    end
    expect(action.call.error).to eq("Couldn't sync user: email taken")
    expect { action.call! }.to raise_error(Axn::Failure, "Couldn't sync user: email taken")
  end

  it "matches the aggregated string at the outer level" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Onboarding failed: Charge failed: card declined")
    expect { outer.call!(inner:) }.to raise_error(Axn::Failure, "Onboarding failed: Charge failed: card declined")
  end

  it "leaves result.exception.message equal to result.error on the non-bang path" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      def call = inner.call!
    end
    r = outer.call(inner:)
    expect(r.exception.message).to eq(r.error)
  end
end

RSpec.describe "user_facing validation parity" do
  it "prefixes the base onto the user-facing validation message and aggregates across call!" do
    inner = build_axn do
      error "Couldn't add note"
      expects :note, user_facing: "Add a note"
      def call = nil
    end
    outer = build_axn do
      expects :inner
      error "Save failed"
      def call = inner.call!(note: nil)
    end
    expect(inner.call(note: nil).error).to eq("Couldn't add note: Add a note")
    expect(outer.call(inner:).error).to eq("Save failed: Couldn't add note: Add a note")
    expect { outer.call!(inner:) }.to raise_error(Axn::ValidationError) { |e|
      expect(e.message).to eq("Save failed: Couldn't add note: Add a note")
    }
  end
end

RSpec.describe "fails_on foreign exception presentation" do
  before { stub_const("ThirdPartyError", Class.new(StandardError)) }

  it "aggregates result.error but preserves the foreign technical message on the exception" do
    inner = build_axn do
      error "Couldn't sync"
      fails_on [ThirdPartyError], "the upstream service is down"
      def call = raise ThirdPartyError, "ECONNREFUSED"
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      fails_on [ThirdPartyError]
      def call = inner.call!
    end

    r = outer.call(inner:)
    expect(r.error).to eq("Onboarding failed: Couldn't sync: the upstream service is down")
    expect(r.exception).to be_a(ThirdPartyError)
    expect(r.exception.message).to eq("ECONNREFUSED") # technical cause preserved, never rewritten
  end
end

RSpec.describe "step interaction with aggregation" do
  it "does not double-count base headers for a step failure" do
    stub_const("Charge", build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end)
    parent = build_axn do
      error "Onboarding failed"
      step :charge, Charge
    end

    msg = parent.call.error
    # Parent base appears exactly once, child base appears exactly once, leaf present.
    # No segment is doubled — step swallows the child via .call and originates a fresh fail!.
    expect(msg.scan("Onboarding failed").size).to eq(1)
    expect(msg.scan("Charge failed").size).to eq(1)
    expect(msg).to include("card declined")
  end
end

RSpec.describe "parent override beats a bubbled child presentation" do
  before { stub_const("NotFoundErr", Class.new(StandardError)) }

  it "uses the parent's matching conditional reason instead of prefixing the carried child message" do
    inner = build_axn do
      error "Child base"
      fails_on [NotFoundErr]
      def call = raise NotFoundErr
    end
    parent = build_axn do
      expects :inner
      error "Parent base"
      error "Record not found", if: NotFoundErr, prefixed: false
      fails_on [NotFoundErr]
      def call = inner.call!
    end
    # The parent's explicit override wins, standalone — not "Parent base: Child base".
    expect(parent.call(inner:).error).to eq("Record not found")
  end
end

RSpec.describe "default_message? is raw-reason based (stamp-independent)" do
  it "stays true for a bare fail! even after #message is stamped with the resolved presentation" do
    action = build_axn do
      error "Onboarding failed"
      def call = fail!
    end
    r = action.call
    expect(r.error).to eq("Onboarding failed")             # base resolved and stamped
    expect(r.exception.message).to eq("Onboarding failed") # #message carries the stamped presentation
    expect(r.exception.default_message?).to be(true) # ...but it was a bare fail!
  end
end

RSpec.describe "exception-bucket aggregation (unexpected exceptions)" do
  it "aggregates declared bases across nested call!, keeping the technical message on the exception" do
    # inner raises a bare RuntimeError -> exception bucket (a bug, not a fail!)
    inner = build_axn do
      error "inner went bad"
      def call = raise "boom"
    end
    outer = build_axn do
      expects :inner
      error "Outer prefix"
      def call = inner.call!
    end
    r = outer.call(inner:)
    expect(r.error).to eq("Outer prefix: inner went bad") # bases chain across the bucket
    expect(r.outcome).to eq("exception")                  # still classified a bug
    expect(r.exception).to be_a(RuntimeError)
    expect(r.exception.message).to eq("boom")             # technical cause untouched, never stamped
  end

  it "does not chain the generic fallback when an inner level declares no base" do
    # inner declares no base
    inner = build_axn { def call = raise "boom" }
    outer = build_axn do
      expects :inner
      error "Outer prefix"
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Outer prefix") # NOT "Outer prefix: Something went wrong"
  end

  it "does not chain the generic fallback for a baseless bare fail! (failure bucket parity)" do
    # baseless inner + bare fail! (no message) resolves to the generic fallback — must not be carried,
    # mirroring the exception bucket (a baseless level contributes nothing).
    inner = build_axn { def call = fail! }
    outer = build_axn do
      expects :inner
      error "Outer prefix"
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Outer prefix") # NOT "Outer prefix: Something went wrong"
  end

  it "carries a declared base even when it legitimately reads like the generic fallback" do
    # base is explicitly declared but happens to equal DEFAULT_ERROR's text — must still be carried
    inner = build_axn do
      error "Something went wrong"
      def call = raise "boom"
    end
    outer = build_axn do
      expects :inner
      error "Outer prefix"
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Outer prefix: Something went wrong")
  end
end

RSpec.describe "aggregation is scoped to transparent call! (no leak through plain .call)" do
  it "does not leak a step child's presentation into the parent on the bug (exception) path" do
    # step runs the child via .call and re-raises the original exception for a bug outcome; the
    # child's presentation must NOT carry into the parent (which only owns the parent-level message).
    child = build_axn do
      error "Child failed"
      def call = raise "boom"
    end
    stub_const("LeakStepChild", child)
    parent = build_axn do
      error "Parent failed"
      step :child, LeakStepChild
    end
    r = parent.call
    expect(r.outcome).to eq("exception")
    expect(r.error).to eq("Parent failed") # NOT "Parent failed: Child failed"
  end

  it "does not leak through an explicit .call + raise r.exception" do
    child = build_axn do
      error "Child failed"
      def call = raise "boom"
    end
    parent = build_axn do
      expects :child
      error "Parent failed"
      def call
        r = child.call
        raise r.exception unless r.ok?
      end
    end
    expect(parent.call(child:).error).to eq("Parent failed")
  end
end

RSpec.describe "carry does not leak after an outermost call!" do
  it "leaves no carried presentation in the store after a rescued top-level call!" do
    # The outermost call!'s `call` has already unwound NestingTracking (and run its reset), so a
    # carry written here would never be consumed or reset — gate it on an active ancestor stack.
    action = build_axn do
      error "Top failed"
      def call = fail!("boom")
    end
    exc = nil
    begin
      action.call!
    rescue Axn::Failure => e
      exc = e
    end
    expect(Axn::Internal::CarriedPresentation.get(exc)).to be_nil
  end
end

RSpec.describe "callbacks observe the stamped presentation" do
  it "on_failure sees exception.message equal to result.error (stamped before callbacks)" do
    seen = []
    action = build_axn do
      error "Checkout failed"
      on_failure { |e| seen << e.message }
      def call = fail!("declined")
    end
    r = action.call
    expect(r.error).to eq("Checkout failed: declined")
    expect(seen).to eq(["Checkout failed: declined"]) # not the raw "declined"
  end
end
