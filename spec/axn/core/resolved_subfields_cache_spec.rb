# frozen_string_literal: true

RSpec.describe "Resolved-subfield cache (PRO-2883)" do
  let(:klass) do
    build_axn do
      expects :payload, type: Hash
      expects :address, type: Hash, optional: true, as: :addr
      expects :meta, on: :payload, type: Hash, optional: true
      expects :locale, on: "payload.meta", type: String, optional: true
      expects :zip, on: :addr, type: String, optional: true
    end
  end

  describe "._resolved_subfields" do
    it "returns the same artifact across reads (cached per class)" do
      expect(klass._resolved_subfields).to equal(klass._resolved_subfields)
    end

    it "rebuilds when a new subfield is declared (identity key misses)" do
      before = klass._resolved_subfields
      klass.expects :note, on: :payload, type: String, optional: true

      after = klass._resolved_subfields
      expect(after).not_to equal(before)
      expect(after.index.keys.map(&:field)).to include(:note)
    end

    it "rebuilds when a new top-level field is declared (roots derive from field configs)" do
      before = klass._resolved_subfields
      klass.expects :extra, type: Hash, optional: true

      after = klass._resolved_subfields
      expect(after).not_to equal(before)
      expect(after.roots).to have_key(:extra)
    end

    it "gives a subclass its own artifact once it declares, without touching the parent's" do
      parent_artifact = klass._resolved_subfields
      child = Class.new(klass)
      child.expects :city, on: :addr, type: String, optional: true

      child_artifact = child._resolved_subfields
      expect(child_artifact).not_to equal(parent_artifact)
      expect(child_artifact.index.keys.map(&:field)).to include(:city)
      # The parent's cache is untouched — its configs' identity never changed.
      expect(klass._resolved_subfields).to equal(parent_artifact)
      expect(klass._resolved_subfields.index.keys.map(&:field)).not_to include(:city)
    end

    it "is deep-frozen (hot-path consumers can never mutate it)" do
      artifact = klass._resolved_subfields
      root = artifact.roots[:payload]

      expect(artifact.roots).to be_frozen
      expect(root.children).to be_frozen
      expect(root.configs).to be_frozen
      expect(artifact.index).to be_frozen
      expect(artifact.dropped).to be_frozen
    end
  end

  describe "the per-config resolved-path index" do
    def path_for(field, on: nil)
      config = klass.subfield_configs.find { |c| c.field == field && (on.nil? || c.on == on) } ||
               klass.internal_field_configs.find { |c| c.field == field }
      klass._resolved_subfields.index[config]
    end

    it "records a top-level field as the depth-0 case" do
      path = path_for(:payload)
      expect(path.wire_path).to eq([:payload])
      expect(path.ancestors).to be_empty
      expect(path.node).to equal(klass._resolved_subfields.roots[:payload])
    end

    it "records a depth-1 subfield's wire path and single hop" do
      path = path_for(:meta)
      expect(path.wire_path).to eq(%i[payload meta])
      expect(path.ancestors.map(&:last)).to eq([:meta])
      expect(path.ancestors.first.first).to equal(klass._resolved_subfields.roots[:payload])
    end

    it "resolves a dotted on: path into per-hop ancestors" do
      path = path_for(:locale)
      expect(path.wire_path).to eq(%i[payload meta locale])
      expect(path.ancestors.map(&:last)).to eq(%i[meta locale])
    end

    it "translates an aliased root reader back to its wire key" do
      # `on: :addr` names the READER (as: alias); the wire path must use the wire key `address`.
      path = path_for(:zip)
      expect(path.wire_path).to eq(%i[address zip])
    end

    it "roots a subfield-anchored chain at the top-level wire key" do
      klass.expects :region, on: :zip, type: String, optional: true

      path = path_for(:region)
      expect(path.wire_path).to eq(%i[address zip region])
      expect(path.ancestors.map(&:last)).to eq(%i[zip region])
    end

    it "resolves a dotted field NAME into implicit intermediate hops" do
      klass.expects "meta.request.id", on: :payload, type: String, optional: true

      path = path_for(:"meta.request.id")
      expect(path.wire_path).to eq(%i[payload meta request id])
      # The intermediate `request` node is implicit (no declaration of its own).
      request_node = path.ancestors[1].first.children[:request]
      expect(request_node.implicit?).to be(true)
    end
  end

  describe "reflection reuse" do
    it "input_schema consumes the cached artifact (no rebuild per call)" do
      expect(Axn::Reflection::SubfieldTree).to receive(:build).once.and_call_original
      klass.input_schema
      klass.input_schema
    end
  end
end
