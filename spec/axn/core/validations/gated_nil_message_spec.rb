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

  # An UNGATED type entry runs on every call, so it runs on every call a gated sibling runs on — the
  # sibling's gate cannot leave a nil unaccounted for, and the type error stands alone.
  it "reports the type error alone though an unrelated sibling carries a nested gate" do
    klass = build_axn do
      expects :flag, type: String, optional: true
      expects :name, type: String, presence: true, inclusion: { in: %w[a b], if: :flag }
    end
    result = klass.call
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
  end

  # With a DECLARATION-level gate the type entry inherits, a sibling that mentions a gate key no longer
  # inherits that gate verbatim: AM's per-key merge lets the sibling run on a call the type check is
  # closed on, so its nil rejection is the only account there is and is not relaxed.
  it "keeps the sibling's account when a nested gate can outlive the declaration gate the type entry rides" do
    klass = build_axn do
      expects :flag, type: :boolean
      expects :name, type: String, if: :flag, presence: { if: nil }
    end
    result = klass.call(flag: false)
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name can't be blank")
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
