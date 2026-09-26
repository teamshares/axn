# frozen_string_literal: true

# The direction invariant for a GATED requirement: the schema never rejects an input the runtime accepts —
# a requirement a closed gate lifts is left out of `required` — and wherever that leaves it accepting an
# input the runtime rejects, it says so in a residue. Where a Symbol gate names a sibling the clause can
# read exactly, it is exact both ways. Each case runs a REAL call and checks the schema's verdict by hand
# (required-array membership + the allOf conditional), so schema and runtime are compared on the same
# concrete input.
RSpec.describe "conditional validation direction audit" do
  # Minimal hand-rolled check: does the input schema (top-level required + allOf clauses +
  # property-level nested required) permit omitting the named keys for this payload?
  def schema_accepts_omission?(schema, payload, omitted_key)
    return false if schema[:required].to_a.include?(omitted_key.to_s)

    Array(schema[:allOf]).all? do |clause|
      cond = clause[:if]
      ref_key = cond[:required].first.to_sym
      ref_present_truthy = payload.key?(ref_key) && ![false, nil].include?(payload[ref_key])
      branch = ref_present_truthy ? clause[:then] : clause[:else]
      !branch || !branch[:required].include?(omitted_key.to_s)
    end
  end

  def residue_paths(action) = action.input_schema_residues.map(&:path)

  it "top-level Proc gate: schema leaves the field optional and names the conditional requirement" do
    action = build_axn do
      expects :flag, type: :boolean
      expects :num, type: Integer, if: -> { flag }
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, { flag: false }, :num)).to be true # never stricter
    expect(action.call(flag: false).ok?).to be true
    expect(schema_accepts_omission?(schema, { flag: true }, :num)).to be true  # looser, and reported
    expect(action.call(flag: true).ok?).to be false
    expect(residue_paths(action)).to include([:num])
  end

  it "declarative Symbol gate: schema and runtime agree on every quadrant" do
    action = build_axn do
      expects :flag, type: :boolean
      expects :num, type: Integer, if: :flag
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, { flag: false }, :num)).to be true
    expect(action.call(flag: false).ok?).to be true
    expect(schema_accepts_omission?(schema, { flag: true }, :num)).to be false
    expect(action.call(flag: true).ok?).to be false
  end

  it "gated subfield, canonical parent-presence condition: the nested requirement is reported, not listed" do
    action = build_axn do
      expects :data, optional: true
      expects :user, type: String, on: :data, if: -> { data.present? }
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, {}, :data)).to be true
    expect(action.call.ok?).to be true
    # A Proc gate cannot be read by the schema, so `user` is not listed as required under `data`; the
    # conditional requirement is named on the property instead.
    expect(Array(schema[:properties][:data][:required])).not_to include("user")
    expect(action.call(data: { role: "x" }).ok?).to be false
    expect(residue_paths(action)).to include(%i[data user])
  end

  it "gated subfield, non-parent condition: the documented looser corner, and only that corner" do
    action = build_axn do
      expects :strict, type: :boolean
      expects :data, optional: true
      expects :user, type: String, on: :data, if: :strict
      def call; end
    end
    schema = action.input_schema
    # The documented divergence: parent omitted + condition true — schema accepts, runtime rejects.
    expect(schema_accepts_omission?(schema, { strict: true }, :data)).to be true
    expect(action.call(strict: true).ok?).to be false
    # Everything else agrees.
    expect(action.call(strict: false).ok?).to be true
    expect(action.call(strict: true, data: { user: "x" }).ok?).to be true
  end

  it "plain boolean unless: gate: schema and runtime agree on every quadrant" do
    action = build_axn do
      expects :skip, type: :boolean
      expects :coupon, type: String, unless: :skip
      def call; end
    end
    schema = action.input_schema
    # gate CLOSED (skip truthy): coupon unvalidated — both accept omission
    expect(schema_accepts_omission?(schema, { skip: true }, :coupon)).to be true
    expect(action.call(skip: true).ok?).to be true
    # gate OPEN (skip falsey): coupon required — both reject omission (exercises the else branch)
    expect(schema_accepts_omission?(schema, { skip: false }, :coupon)).to be false
    expect(action.call(skip: false).ok?).to be false
  end

  it "blank same-key nested override: schema requires unconditionally (stricter-or-exact, never looser)" do
    action = build_axn do
      expects :flag, type: :boolean
      expects :name, type: String, if: :flag, presence: { if: nil }
      def call; end
    end
    schema = action.input_schema
    # The nested `if: nil` drops the shared `if: :flag` for the presence check, so presence runs
    # unconditionally — name is required for EVERY call. The clause falls back to unconditional required
    # rather than emitting a `flag`-conditional allOf that would (looser) accept `{flag: false}` sans name.
    expect(schema[:allOf]).to be_nil
    expect(schema[:required]).to include("name")
    # Direction holds on the wire value that used to slip through: schema rejects the omission, runtime does too.
    expect(schema_accepts_omission?(schema, { flag: false }, :name)).to be false
    expect(action.call(flag: false).ok?).to be false
    # And when the gate is "open" runtime still requires name (gate is moot) — schema agrees, exact here.
    expect(schema_accepts_omission?(schema, { flag: true }, :name)).to be false
    expect(action.call(flag: true).ok?).to be false
  end

  it "coerced-boolean unless: reference: the inexact clause falls back to optional, never to required" do
    action = build_axn do
      expects :skip, coerce: [:boolean, String]
      expects :coupon, type: String, unless: :skip
      def call; end
    end
    schema = action.input_schema
    # Boolean coercion reads the wire value differently from the emitted `if`, so no clause is exact, and an
    # unconditional `required` would reject `{skip: "true"}`, which the runtime accepts.
    expect(schema[:allOf]).to be_nil
    expect(Array(schema[:required])).not_to include("coupon")
    expect(schema_accepts_omission?(schema, { skip: "true" }, :coupon)).to be true
    expect(action.call(skip: "true").ok?).to be true
    # wire "false" coerces to false, the gate opens and coupon is required: looser, and reported.
    expect(schema_accepts_omission?(schema, { skip: "false" }, :coupon)).to be true
    expect(action.call(skip: "false").ok?).to be false
    expect(residue_paths(action)).to include([:coupon])
  end

  it "coerced-boolean if: reference: falls back the same way, since the flip makes the clause stricter" do
    action = build_axn do
      expects :flag, coerce: [:boolean, String]
      expects :coupon, type: String, if: :flag
      def call; end
    end
    schema = action.input_schema
    # wire "false" is truthy to the emitted `if` and falsey once coerced, closing the runtime gate.
    expect(schema[:allOf]).to be_nil
    expect(schema_accepts_omission?(schema, { flag: "false" }, :coupon)).to be true
    expect(action.call(flag: "false").ok?).to be true
    expect(residue_paths(action)).to include([:coupon])
  end
end
