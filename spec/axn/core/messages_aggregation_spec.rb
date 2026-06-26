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
