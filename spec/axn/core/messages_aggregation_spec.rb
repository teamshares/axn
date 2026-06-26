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
