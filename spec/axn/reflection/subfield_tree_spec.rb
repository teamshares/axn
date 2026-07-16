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
      expects :baz, on: "foo.bar", type: String
      expects :bar, on: :foo, type: Hash
    end
    tree = tree_for(klass)

    bar = tree.roots[:foo].children[:bar]
    # The implicit node created by the dotted `on: "foo.bar"` and the explicit :bar declaration are the same node.
    expect(bar.configs.map(&:field)).to eq([:bar])
    expect(bar).not_to be_implicit
    expect(bar.children[:baz].config.field).to eq(:baz)
  end

  it "merges two routes to the SAME wire path (dotted on: + reader-anchored via as:) onto one node" do
    # A merged leaf node needs two configs at one wire path; both therefore share the leaf wire key,
    # so they are NOT duplicates (they differ by `on:` route). Distinct readers via `as:` keep the
    # reader table unambiguous. (The dotted-NAME spelling that used to reach this is gone, PRO-2926.)
    klass = Class.new do
      include Axn
      expects :foo, type: Hash
      expects :bar, on: :foo, type: Hash
      expects :baz, on: "foo.bar", type: String
      expects :baz, on: :bar, as: :bar_baz, type: String
    end
    tree = tree_for(klass)

    baz = tree.roots[:foo].children[:bar].children[:baz]
    expect(baz.configs.size).to eq(2)
    expect(baz.configs.map(&:field)).to eq(%i[baz baz])
  end

  it "allows two subfields sharing a leaf wire key under DIFFERENT parents (distinct readers via as:)" do
    klass = Class.new do
      include Axn
      expects :billing, type: Hash
      expects :shipping, type: Hash
      expects :zip, on: :billing, type: String, as: :billing_zip
      expects :zip, on: :shipping, type: String, as: :shipping_zip
    end
    tree = tree_for(klass)

    expect(tree.roots[:billing].children[:zip].config.field).to eq(:zip)
    expect(tree.roots[:shipping].children[:zip].config.field).to eq(:zip)
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

    it "drops a deep config whose implicit intermediate collides with a non-object shape member" do
      # The colliding member is a `[Hash, String]` union: non-nestable (the String branch blocks the drop
      # pass) yet answerable (the Hash branch reads a key), so it survives the unanswerable-segment check while still dropping.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: [Hash, String]
        end
        expects :baz, on: "payload.bar", type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:baz])
    end

    it "drops a deep config whose implicit intermediate collides with a mixed-union shape member" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: [Hash, Array]
        end
        expects :baz, on: "payload.bar", type: String
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:baz])
    end

    it "drops a deep config colliding with a non-object shape member declared on a merged node's SECOND config" do
      # baz is a merged node (two routes: `:baz, on: "foo.bar"` and `:baz, on: :bar`); only the SECOND config
      # carries the non-nestable member x (`[Hash, String]` — blocks the drop pass, yet answerable at declaration).
      # blocking_ancestor? scans EVERY config at the node, so the deep `bar.baz.x.y` still drops.
      # (Subfields take no block, so the shape rides a raw `shape:` kwarg — the block DSL's own structure.)
      x_member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: [Hash, String] }, presence: true }, metadata: {})
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: Hash
        expects :baz, on: "foo.bar", type: Hash
        expects :baz, on: :bar, as: :bar_baz, type: Hash, shape: { members: [x_member], container: Hash }
        expects :y, on: "bar.baz.x"
      end
      tree = tree_for(klass)

      baz = tree.roots[:foo].children[:bar].children[:baz]
      expect(baz.configs.size).to eq(2) # merged node
      expect(tree.dropped.map(&:field)).to eq([:y])
    end

    it "drops a deep config when merged colliding members carry DISAGREEING nested members (all carried, not just the first nestable)" do
      # baz is a merged node; both routes declare a nestable Hash member `x`, but their NESTED members at
      # `y` disagree — route 1's `y` is a Hash (nestable), route 2's `y` is a non-nestable `[Hash, String]`
      # union. Carrying only the FIRST nestable `x` would test route 1's `y` alone and NOT drop; carrying
      # ALL colliding members tests route 2's union `y` and drops `baz.x.y.z`, matching emission (which carries
      # every member). The union stays answerable at declaration (the Hash branch) while blocking the drop pass.
      y1 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: Hash } }, metadata: {})
      x1 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y1], container: Hash } }, metadata: {})
      y2 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: [Hash, String] }, presence: true }, metadata: {})
      x2 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y2], container: Hash } }, metadata: {})
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: Hash
        expects :baz, on: "foo.bar", type: Hash, shape: { members: [x1], container: Hash }
        expects :baz, on: :bar, as: :bar_baz, type: Hash, shape: { members: [x2], container: Hash }
        expects :z, on: "baz.x.y"
      end
      tree = tree_for(klass)

      baz = tree.roots[:foo].children[:bar].children[:baz]
      expect(baz.configs.size).to eq(2) # merged node
      expect(tree.dropped.map(&:field)).to eq([:z])
    end

    it "drops a deep config whose implicit intermediate collides with a non-object member of a member (carried through implicit descent)" do
      # `baz` is a `[Hash, String]` member-of-a-member: non-nestable (blocks the drop pass at depth 2)
      # yet answerable via its Hash branch, so the declaration is accepted while `payload.bar.baz.qux` drops.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: Hash do
            field :baz, type: [Hash, String]
          end
        end
        expects :qux, on: "payload.bar.baz"
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:qux])
    end

    it "drops a deep config whose implicit intermediate collides with a mixed-union member of a member" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: Hash do
            field :baz, type: [Hash, Array]
          end
        end
        expects :qux, on: "payload.bar.baz"
      end
      tree = tree_for(klass)

      expect(tree.dropped.map(&:field)).to eq([:qux])
    end

    it "does NOT drop a deep config nesting through an OBJECT member of a member (member-of-member is nestable)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :bar, type: Hash do
            field :baz, type: Hash
          end
        end
        expects :qux, on: "payload.bar.baz"
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
        expects :baz, on: "payload.bar"
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
