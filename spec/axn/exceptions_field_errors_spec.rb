# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::InboundValidationError do
  def errors_with(&block)
    e = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
    block.call(e)
    e
  end

  it "maps each error to {field:, message:} using the full message" do
    errors = errors_with { |e| e.add(:name, "is not a String") }
    exc = described_class.new(errors)
    expect(exc.field_errors).to eq([{ field: :name, message: "Name is not a String" }])
  end

  it "surfaces base-level errors with field == :base" do
    errors = errors_with { |e| e.add(:base, "unknown input: bogus") }
    exc = described_class.new(errors)
    expect(exc.field_errors).to eq([{ field: :base, message: "unknown input: bogus" }])
  end

  it "is empty when there are no errors" do
    exc = described_class.new(errors_with { |_e| })
    expect(exc.field_errors).to eq([])
  end
end
