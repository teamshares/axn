# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::SubfieldContradictions do
  def tree_for(&blk)
    klass = build_axn(&blk)
    Axn::Reflection::SubfieldTree.build(klass.internal_field_configs, klass.subfield_configs)
  end

  describe ".detect" do
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
end
