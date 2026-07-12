# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::SubfieldContradictions do
  def tree_for(&blk)
    klass = build_axn(&blk)
    Axn::Reflection::SubfieldTree.build(klass.internal_field_configs, klass.subfield_configs)
  end

  describe ".detect" do
    # A contradiction-only contract can't be built through the DSL at all (declaration raises before the
    # tree is ever handed to detect) — that raise is exercised in on_subfields_spec.rb's "family 1"
    # examples. This confirms the converse: a legitimately contradiction-free tree detects nothing.
    it "returns nil for a contradiction-free contract (nested, nil-tolerant, dotted)" do
      tree = tree_for do
        expects :payload, type: Hash, allow_nil: true
        expects :meta, on: :payload, type: Hash, optional: true
        expects :id, on: "payload.meta", type: Integer, optional: true
      end

      expect(described_class.detect(tree)).to be_nil
    end
  end

  describe ".label" do
    it "renders a top-level field config (no on:) as just :field" do
      tree = tree_for { expects :payload, type: Hash }

      expect(described_class.label(tree.roots[:payload].config)).to eq(":payload")
    end

    it "renders a subfield config (has on:) with its on: path" do
      tree = tree_for do
        expects :payload, type: Hash
        expects :name, on: :payload, type: String, optional: true
      end

      expect(described_class.label(tree.roots[:payload].children[:name].config)).to eq(":name (on: payload)")
    end
  end

  describe ".first_leaf_config" do
    it "returns the node's own config for an explicit (non-implicit) node" do
      tree = tree_for { expects :payload, type: Hash }
      node = tree.roots[:payload]

      expect(described_class.first_leaf_config(node)).to eq(node.config)
    end

    it "descends through an implicit intermediate to the first explicit descendant's config" do
      tree = tree_for do
        expects :payload, type: Hash
        expects :id, on: "payload.meta", type: Integer, optional: true
      end
      implicit_meta = tree.roots[:payload].children[:meta]

      expect(implicit_meta).to be_implicit
      expect(described_class.first_leaf_config(implicit_meta).field).to eq(:id)
    end
  end
end
