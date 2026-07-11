# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::SubfieldTree do
  def tree_for(klass)
    described_class.build(klass.internal_field_configs, klass.subfield_configs)
  end

  it "groups shallow subfields as direct children of their top-level root, keyed by wire key" do
    klass = Class.new do
      include Axn
      expects :address, type: Hash
      expects :zip, on: :address, type: String
    end
    tree = tree_for(klass)

    root = tree.roots[:address]
    expect(root.config.field).to eq(:address)
    expect(root.children.keys).to eq([:zip])
    expect(root.children[:zip].config.field).to eq(:zip)
    expect(root.children[:zip]).not_to be_implicit
    expect(tree.dropped).to eq([])
  end

  it "expands a dotted on: path into implicit intermediate nodes" do
    klass = Class.new do
      include Axn
      expects :payload, type: Hash
      expects :zip, on: "payload.address", type: String
    end
    tree = tree_for(klass)

    address = tree.roots[:payload].children[:address]
    expect(address).to be_implicit
    expect(address.children[:zip].config.field).to eq(:zip)
    expect(tree.dropped).to eq([])
  end

  it "expands a dotted field name into implicit intermediate nodes under the parent" do
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects "bar.baz", on: :foo, type: String
    end
    tree = tree_for(klass)

    bar = tree.roots[:foo].children[:bar]
    expect(bar).to be_implicit
    expect(bar.children[:baz].config.field).to eq(:"bar.baz")
  end

  it "anchors a subfield-of-a-subfield under the parent subfield's node, resolving on: through the READER (as: alias) while keying children by WIRE KEY" do
    klass = Class.new do
      include Axn
      expects :payload, type: Hash, as: :data
      # `:details` (not `:info`, a built-in logging reader) aliases the :meta subfield.
      expects :meta, on: :data, type: Hash, as: :details
      expects :id, on: :details, type: Integer
    end
    tree = tree_for(klass)

    # Roots are keyed by reader_as (:data); children by wire key (:meta, :id).
    meta = tree.roots[:data].children[:meta]
    expect(meta.config.field).to eq(:meta)
    expect(meta.children[:id].config.field).to eq(:id)
  end

  it "merges two declaration routes to the same wire path onto one node, in declaration order" do
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects "bar.baz", on: :foo, type: String
      expects :bar, on: :foo, type: Hash
    end
    tree = tree_for(klass)

    bar = tree.roots[:foo].children[:bar]
    # The implicit node created by "bar.baz" and the explicit :bar declaration are the same node.
    expect(bar.configs.map(&:field)).to eq([:bar])
    expect(bar).not_to be_implicit
    expect(bar.children[:baz].config.field).to eq(:"bar.baz")
  end

  it "silently skips an on: :ambient_context subfield with no declared ambient field (excluded, not dropped)" do
    klass = Class.new do
      include Axn
      expects :company, on: :ambient_context, type: Integer
    end
    tree = tree_for(klass)

    expect(tree.roots).to eq({})
    expect(tree.dropped).to eq([])
  end

  describe "dropped (deep configs with no JSON-object representation)" do
    it "drops a deep config under a model: ancestor but keeps it in the tree for requiredness" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:name])
      expect(tree.roots[:user].children[:profile].children[:name].config.field).to eq(:name)
    end

    it "drops a deep config under a non-object (Array) ancestor, even one declared AFTER the deep config" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.items", type: String
        expects :items, on: :payload, type: Array
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:zip])
    end

    it "drops a deep config under a mixed-union ancestor" do
      klass = Class.new do
        include Axn
        expects :payload, type: [Hash, Array]
        expects :id, on: "payload.meta", type: Integer
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:id])
    end

    it "drops a deep config whose implicit intermediate collides with a non-object shape member" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: String
        end
        expects "bar.baz", on: :payload, type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:"bar.baz"])
    end

    it "drops a deep config whose implicit intermediate collides with a mixed-union shape member" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: [Hash, Array]
        end
        expects "bar.baz", on: :payload, type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:"bar.baz"])
    end

    it "does not drop a representable deep chain (object-shaped explicit ancestors)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
        expects :deep, on: "payload.meta", type: String
        expects "bar.baz", on: :payload
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
    end

    it "never drops a depth-1 subfield, even under a non-object parent (silent omission is preserved)" do
      klass = Class.new do
        include Axn
        expects :items, type: Array
        expects :length, on: :items, type: Integer
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
    end
  end
end
