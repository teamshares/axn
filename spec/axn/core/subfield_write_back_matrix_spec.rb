# frozen_string_literal: true

# Runtime-truth matrix for the subfield write-back paths (defaults + preprocess), pinned BEFORE the
# PRO-2883 chain-aware refactor so the refactor is verified against observed behavior, not intended
# behavior. Every example here must hold identically before and after.
RSpec.describe "Subfield write-back runtime truth (PRO-2883)" do
  describe "defaults" do
    it "materializes a nil untyped parent as {} so the default lands" do
      action = build_axn do
        expects :payload, allow_nil: true
        expects :note, on: :payload, optional: true, type: String, default: "d"
        exposes :got, :parent, optional: true, allow_nil: true

        def call = expose(got: note, parent: payload)
      end

      result = action.call(payload: nil)
      expect(result).to be_ok
      expect(result.got).to eq("d")
      expect(result.parent).to eq({ note: "d" })
    end

    it "materializes an absent Hash-typed parent" do
      action = build_axn do
        expects :payload, type: Hash, optional: true, allow_nil: true
        expects :note, on: :payload, optional: true, type: String, default: "d"
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call.got).to eq("d")
    end

    it "refuses to materialize a non-object (type: Array) parent — the default is skipped, the parent stays nil" do
      action = build_axn do
        expects :payload, type: Array, optional: true, allow_nil: true
        expects :length, on: :payload, optional: true, default: 9
        exposes :parent, optional: true, allow_nil: true

        def call = expose(parent: payload)
      end

      result = action.call
      expect(result).to be_ok
      expect(result.parent).to be_nil
    end

    it "does not overwrite a present subfield value" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, optional: true, type: String, default: "d"
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call(payload: { note: "explicit" }).got).to eq("explicit")
    end

    it "fills a nil subfield value under a present parent" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, optional: true, type: String, default: "d"
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call(payload: { note: nil, other: 1 }).got).to eq("d")
    end

    it "applies default: false (kwarg parity: non-nil defaults apply, matching top-level semantics)" do
      action = build_axn do
        expects :payload, type: Hash
        expects :flag, on: :payload, optional: true, type: :boolean, default: false
        exposes :got, optional: true, allow_nil: true, type: :boolean

        def call = expose(got: flag)
      end

      expect(action.call(payload: { other: 1 }).got).to be(false)
    end

    it "instance_execs a Proc default against the action" do
      action = build_axn do
        expects :seed, type: Integer
        expects :payload, type: Hash
        expects :note, on: :payload, optional: true, type: Integer, default: -> { seed * 2 }
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call(seed: 4, payload: { other: 1 }).got).to eq(8)
    end

    it "creates intermediate hashes for a dotted-name default under a present parent" do
      action = build_axn do
        expects :payload, type: Hash
        expects "meta.note", on: :payload, optional: true, default: "d"
        exposes :parent, optional: true

        def call = expose(parent: payload)
      end

      expect(action.call(payload: { other: 1 }).parent).to eq({ other: 1, meta: { note: "d" } })
    end

    it "materializes the whole chain for a dotted-name default under a nil parent" do
      action = build_axn do
        expects :payload, type: Hash, optional: true, allow_nil: true
        expects "meta.note", on: :payload, optional: true, default: "d"
        exposes :parent, optional: true, allow_nil: true

        def call = expose(parent: payload)
      end

      expect(action.call.parent).to eq({ meta: { note: "d" } })
    end

    it "applies interacting dotted defaults in declaration order (deeper-first declaration wins the skip)" do
      # `meta.x`'s default runs first (declaration order) and creates `meta`, so `meta`'s own default
      # sees a present value and skips. Pinned: the defaults pass runs in declaration order.
      action = build_axn do
        expects :payload, type: Hash, optional: true, allow_nil: true
        expects "meta.x", on: :payload, optional: true, default: 1
        expects :meta, on: :payload, optional: true, type: Hash, default: { y: 2 }
        exposes :parent, optional: true, allow_nil: true

        def call = expose(parent: payload)
      end

      expect(action.call.parent).to eq({ meta: { x: 1 } })
    end

    it "writes through a setter when the parent is an object (not a Hash)" do
      holder = Struct.new(:note, :other)
      action = build_axn do
        expects :payload, type: holder
        expects :note, on: :payload, optional: true, default: "d"
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call(payload: holder.new(nil, 1)).got).to eq("d")
    end
  end

  describe "preprocess" do
    it "transforms a present subfield value" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, optional: true, preprocess: ->(v) { v.to_s.upcase }
        exposes :got, optional: true

        def call = expose(got: note)
      end

      expect(action.call(payload: { note: "hi" }).got).to eq("HI")
    end

    it "drops the preprocess result when the parent is nil (never synthesizes the parent)" do
      action = build_axn do
        expects :payload, type: Hash, optional: true, allow_nil: true
        expects :note, on: :payload, optional: true, preprocess: ->(v) { "#{v}!" }
        exposes :got, :parent, optional: true, allow_nil: true

        def call = expose(got: note, parent: payload)
      end

      result = action.call(payload: nil)
      expect(result).to be_ok
      expect(result.parent).to be_nil
      expect(result.got).to be_nil
    end

    it "does not mutate the caller's parent hash (simple key write-back is copy-on-write)" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, optional: true, preprocess: ->(v) { v.to_s.upcase }

        def call = nil
      end

      callers_hash = { note: "hi" }
      expect(action.call(payload: callers_hash)).to be_ok
      expect(callers_hash).to eq({ note: "hi" })
    end
  end
end
