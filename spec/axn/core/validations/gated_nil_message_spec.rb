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

  # AM merges the two gate tiers PER KEY, so a sibling naming a key the declaration does NOT carry keeps
  # the shared gate and merely adds a condition — it can only run on a subset of the calls the type check
  # runs on, leaving no nil for it alone to account for.
  it "reports the type error alone when a sibling's nested gate names a key the declaration does not carry" do
    klass = build_axn do
      expects :enabled, type: String, optional: true
      expects :skip, type: String, optional: true
      expects :name, type: String, presence: { unless: :skip }, if: :enabled
    end
    result = klass.call(enabled: "y")
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
  end

  # The same-key counterpart: the sibling's own `if:` REPLACES the shared one, so it runs on a call the
  # type check is closed on and its nil rejection is the only account there.
  it "keeps the sibling's account when its nested gate replaces the declaration gate by name" do
    klass = build_axn do
      expects :enabled, type: String, optional: true
      expects :other, type: String, optional: true
      expects :name, type: String, presence: { if: :other }, if: :enabled
    end
    result = klass.call(enabled: "y", other: "z")
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String and Name can't be blank")
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

  # ActiveModel ignores a blank condition, so a blank gate key on the type entry with no declaration gate
  # to override gates nothing: the type check is as unconditional as a bare `type:` and runs on every call
  # any sibling runs on. Mentioning a key is only a hazard when it can DROP a gate the type check would
  # otherwise ride.
  it "reports the type error alone for a blank gate key the type entry carries on its own" do
    klass = build_axn do
      expects :name, type: { klass: String, if: nil }
    end
    result = klass.call
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
  end

  # The blank same-key override on the TYPE entry: it drops the declaration's gate for the type check
  # alone, leaving it unconditional while its siblings stay gated — still a superset of every call they
  # run on, so the type error remains the complete account.
  it "reports the type error alone when a blank gate key on the type entry drops the declaration gate" do
    klass = build_axn do
      expects :flag, type: :boolean
      expects :name, type: { klass: String, if: nil }, if: :flag
    end
    result = klass.call(flag: true)
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
    # The type check runs even with the declaration gate closed, and still reports alone.
    expect(klass.call(flag: false).exception.message).to eq("Name is not a String")
  end

  # A blank key the DECLARATION does not carry drops nothing, so the type check keeps riding the
  # declaration's other gate — and a sibling replacing that gate can still outlive it.
  it "keeps the sibling's account when a blank key on the type entry leaves the declaration gate standing" do
    klass = build_axn do
      expects :flag, type: :boolean
      expects :name, type: { klass: String, unless: nil }, if: :flag, presence: { if: :flag }
    end
    result = klass.call(flag: true)
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String and Name can't be blank")
  end
end
