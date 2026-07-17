# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Internal::CurrentCallOptions do
  after { described_class.current = nil }

  it "defaults to no current options" do
    expect(described_class.current).to be_nil
  end

  it "sets options within a `with` block and restores afterward" do
    described_class.with(user_facing_input_errors: true) do
      expect(described_class.current.user_facing_input_errors).to be(true)
      expect(described_class.current.coerce_input_types).to be_nil
      expect(described_class.current.reject_undeclared_inputs).to be(false)
    end
    expect(described_class.current).to be_nil
  end

  it "restores the prior value even when the block raises" do
    expect do
      described_class.with(coerce_input_types: true) { raise "boom" }
    end.to raise_error("boom")
    expect(described_class.current).to be_nil
  end

  it "consume returns the current options and clears the holder" do
    described_class.with(reject_undeclared_inputs: true) do
      consumed = described_class.consume
      expect(consumed.reject_undeclared_inputs).to be(true)
      expect(described_class.current).to be_nil
    end
  end

  it "consume returns nil when nothing is set" do
    expect(described_class.consume).to be_nil
  end
end
