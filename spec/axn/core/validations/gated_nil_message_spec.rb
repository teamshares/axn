# frozen_string_literal: true

RSpec.describe "a conditionally-required field's message for a nil" do
  it "reports the type error alone, as an unconditionally-required field does" do
    klass = build_axn do
      expects :flag, type: String
      expects :name, type: String, if: :flag
    end
    result = klass.call(flag: "x")
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
  end

  it "still lets a sibling reject the nil when the gate is on the TYPE ENTRY alone" do
    klass = build_axn do
      expects :flag, type: String, optional: true
      expects :name, type: { klass: String, if: :flag }, presence: true
    end
    result = klass.call
    expect(result).not_to be_ok
    expect(result.exception.message).to include("Name can't be blank")
  end
end
