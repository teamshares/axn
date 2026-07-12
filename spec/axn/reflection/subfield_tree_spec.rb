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

    it "does NOT drop a NON-dotted model name reached via a dotted on: (a reader IS generated)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :org, on: :payload, type: Hash
        expects :company, on: "payload.org", model: { klass: Struct.new(:id), finder: :find }
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
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

    # A deep config whose implicit intermediate collides with a non-object/mixed-union shape member (at
    # any depth, including a member-of-a-member, and however the merge is assembled) is no longer
    # dropped+warned: it now raises ArgumentError at declaration (PRO-2877 family 2 — see
    # subfield_contradictions_spec.rb and on_subfields_spec.rb's "family 2" examples for the message
    # contract). The structural variants below are converted to declaration-raise assertions rather than
    # deleted, since each still exercises a distinct shape of the underlying collision.

    it "raises at declaration when an implicit intermediate collides with a non-object shape member" do
      expect do
        Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.baz", on: :payload, type: String
        end
      end.to raise_error(ArgumentError, /:bar\.baz \(on: payload\) nests beneath shape member :bar on :payload/)
    end

    it "raises at declaration when an implicit intermediate collides with a mixed-union shape member" do
      expect do
        Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, Array]
          end
          expects "bar.baz", on: :payload, type: String
        end
      end.to raise_error(ArgumentError, /:bar\.baz \(on: payload\) nests beneath shape member :bar on :payload/)
    end

    it "raises at declaration when a non-object shape member declared on a merged node's SECOND config collides" do
      # baz is a merged node (two routes: `bar.baz` and `baz`); only the SECOND config carries the scalar
      # member x. The drop pass (path_blocked? / node_configs_block_nesting?) scans EVERY config at the
      # node, so the deep `baz.x.y` still collides.
      # (Subfields take no block, so the shape rides a raw `shape:` kwarg — the block DSL's own structure.)
      x_member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String }, presence: true }, metadata: {})
      expect do
        Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: Hash
          expects :baz, on: :bar, type: Hash, shape: { members: [x_member], container: Hash }
          expects "baz.x.y", on: :bar
        end
      end.to raise_error(ArgumentError, /:baz\.x\.y \(on: bar\) nests beneath shape member :x on :baz/)
    end

    it "raises at declaration when merged colliding members carry DISAGREEING nested members (all carried, not just the first nestable)" do
      # baz is a merged node; both routes declare a nestable Hash member `x`, but their NESTED members at
      # `y` disagree — route 1's `y` is a Hash (nestable), route 2's `y` is a scalar String. Carrying only
      # the FIRST nestable `x` would test route 1's `y` alone and not collide; carrying ALL colliding
      # members tests route 2's scalar `y` too, matching emission (which carries every member).
      y1 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: Hash } }, metadata: {})
      x1 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y1], container: Hash } }, metadata: {})
      y2 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: String }, presence: true }, metadata: {})
      x2 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y2], container: Hash } }, metadata: {})
      expect do
        Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: Hash, shape: { members: [x1], container: Hash }
          expects :baz, on: :bar, type: Hash, shape: { members: [x2], container: Hash }
          expects "x.y.z", on: :baz
        end
      end.to raise_error(ArgumentError, /:x\.y\.z \(on: baz\) nests beneath shape member :y on :x/)
    end

    it "raises at declaration when an implicit intermediate collides with a SCALAR member of a member (carried through implicit descent)" do
      expect do
        Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: String
            end
          end
          expects "bar.baz.qux", on: :payload
        end
      end.to raise_error(ArgumentError, /:bar\.baz\.qux \(on: payload\) nests beneath shape member :baz on :bar/)
    end

    it "raises at declaration when an implicit intermediate collides with a mixed-union member of a member" do
      expect do
        Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: [Hash, Array]
            end
          end
          expects "bar.baz.qux", on: :payload
        end
      end.to raise_error(ArgumentError, /:bar\.baz\.qux \(on: payload\) nests beneath shape member :baz on :bar/)
    end

    it "does NOT drop a deep config nesting through an OBJECT member of a member (member-of-member is nestable)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: Hash do
            field :baz, type: Hash
          end
        end
        expects "bar.baz.qux", on: :payload
      end
      tree = tree_for(klass)

      expect(tree.dropped).to eq([])
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
