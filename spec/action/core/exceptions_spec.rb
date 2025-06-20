# frozen_string_literal: true

# NOTE: remnant from previous more-complex behavior, leaving just to confirm basic here.
RSpec.describe Action::Failure do
  it "defaults to the default message" do
    expect(described_class.new.message).to eq(described_class::DEFAULT_MESSAGE)
  end

  context "with a custom message" do
    it "uses the custom message" do
      expect(described_class.new("foo").message).to eq("foo")
    end
  end
end
