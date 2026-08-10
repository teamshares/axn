# frozen_string_literal: true

require "spec_helper"

# `crossed_node` answers "does this config resolve its parent through a node it never named?" — the one
# question both the runtime reader dispatch (_deepest_reader_name) and the ambiguous-crossing declaration
# check ask, so they cannot disagree about which reference is unnamed.
RSpec.describe "the unnamed-crossing seam (PRO-3068)" do
  subject(:klass) do
    build_axn do
      expects :payload, type: Hash
      expects :bar, on: :payload, type: Hash
      expects :count, on: "payload.bar", optional: true  # dotted tail: crosses :bar without naming it
      expects :named, on: :bar, optional: true           # names :bar's reader
    end
  end

  def seam_for(field)
    config = klass.send(:subfield_configs).find { |c| c.field == field }
    [config, klass._resolved_subfields.index[config]]
  end

  it "returns the node a dotted tail crosses without naming it" do
    node = Axn::Core::ContractForSubfields.crossed_node(*seam_for(:count))

    expect(node.configs.map(&:reader_as)).to eq([:bar])
  end

  it "returns nil when the config anchors on that node by reader name" do
    expect(Axn::Core::ContractForSubfields.crossed_node(*seam_for(:named))).to be_nil
  end

  it "returns nil for a top-level config, which reads no segment at all" do
    config = klass.internal_field_configs.find { |c| c.field == :payload }
    path = klass._resolved_subfields.index[config]

    expect(Axn::Core::ContractForSubfields.crossed_node(config, path)).to be_nil
  end

  it "reports the anchor's own chain index for a dotted on:" do
    config, path = seam_for(:count)

    # `on: "payload.bar"` — one segment below the root, so the anchor sits one hop above the on: target.
    expect(Axn::Core::ContractForSubfields.anchor_index(config, path)).to eq(path.parent_index - 1)
  end
end
