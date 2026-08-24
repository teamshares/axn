# frozen_string_literal: true

RSpec.describe Axn::Core::Contract::SubfieldContradictions do
  it "belongs to the contract layer it validates, not to the reflection layer" do
    expect(Axn::Core::Contract.const_defined?(:SubfieldContradictions, false)).to be(true)
    expect(Axn::Internal::Reflection.const_defined?(:SubfieldContradictions, false)).to be(false)
  end

  let(:company_class) do
    Class.new do
      attr_accessor :id, :name

      def initialize(id:, name: nil)
        @id = id
        @name = name
      end

      def self.fetch(id) = new(id:)
    end
  end

  before { stub_const("DeadCo", company_class) }

  describe "dead nil-tolerance rejection" do
    it "rejects a nil-tolerant top-level parent with an unrescued required deep descendant" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant.*:meta\.id.*required/m)
    end

    it "rejects a nil-tolerant INTERMEDIATE subfield with a required child" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :id, on: :meta, type: Integer
        end
      end.to raise_error(ArgumentError, /:meta is declared nil-tolerant/)
    end

    it "rejects optional: spelling the same way" do
      expect do
        build_axn do
          expects :payload, type: Hash, optional: true
          expects :id, on: :payload, type: Integer
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant/)
    end

    # The rescue tail as living specs — all LEGAL:
    it "accepts a literal default on the stranded node" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: 42
        end
      end.not_to raise_error
    end

    it "accepts a Proc default on the stranded node (unknowable → satisfiable)" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: -> { 42 }
        end
      end.not_to raise_error
    end

    it "accepts a usable default on the parent itself" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true, default: { meta: { id: 1 } }
          expects :id, on: "payload.meta", type: Integer
        end
      end.not_to raise_error
    end

    it "accepts a merged-route default declared first (the sibling route's wire value rescues)" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :meta, on: :payload, type: Hash, optional: true, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: 5, as: :meta_id
          expects :id, on: :meta, type: Integer
        end
      end.not_to raise_error
    end

    it "rejects a blank default that an active presence validator would reject" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :name, on: :payload, type: String, default: ""
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant/)
    end

    it "accepts a blank default when no active presence validator rejects it" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :name, on: :payload, presence: false, default: ""
        end
      end.not_to raise_error
    end
  end

  describe "conditionally gated required subfields (PRO-2881)" do
    it "accepts a nil-tolerant parent whose required subfield is gated (the tolerance is exercisable)" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data, if: -> { data.present? }
        end
      end.not_to raise_error
    end

    it "still rejects when an UNGATED required sibling strands the parent" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data, if: -> { data.present? }
          expects :role, type: String, on: :data
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "accepts a merged node whose only UNGATED route is itself omittable (optional:)" do
      # `root.data.user` is reached by two routes: an UNGATED `optional:` route (`:user on: :data`) and
      # a gated required route (`:user on: "root.data"` under `:strict`). Ancestor-forcing derives from
      # the ungated subset alone — the ungated route is omittable, so it strands nothing, and `:data`'s
      # tolerance stays exercisable (gate closed + data omitted validates).
      expect do
        build_axn do
          expects :strict, type: :boolean, default: false
          expects :root, type: Hash, allow_blank: true
          expects :data, on: :root, optional: true
          expects :user, on: :data, type: String, optional: true
          expects :user, on: "root.data", type: String, if: :strict, as: :strict_user
        end
      end.not_to raise_error
    end

    it "accepts a nil-tolerant parent whose subfield is gated by a per-validator (nested) presence condition" do
      # The documented per-validator form: `presence: { if: ... }` gates the lone nil-rejecting check,
      # so the child can't force `:data` — the tolerance is exercisable and declaration must not reject.
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, on: :data, presence: { if: -> { data.present? } }
        end
      end.not_to raise_error
    end

    it "still rejects a nested-gated presence sitting ALONGSIDE an ungated nil-rejecting type under an optional parent" do
      # Only a FULLY-relaxable config relaxes: the ungated `type: String` still rejects a nil `user`, so
      # the parent tolerance stays dead. (Contrast the accepted case above, where presence is the only check.)
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, on: :data, type: String, presence: { if: -> { data.present? } }
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "points the rejection message at the conditional spelling" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data
        end
      end.to raise_error(ArgumentError, /gate it conditionally.*if: -> \{ data\.present\? \}/m)
    end

    it "REJECTS a blank same-key nested override that un-gates the presence check (Codex round 14)" do
      # `presence: { if: nil }` drops the declaration `if: :flag` for the presence check (AM's measured
      # per-key merge), so presence runs UNCONDITIONALLY — `:data` omitted makes `user` resolve nil and
      # presence fails. The tolerance is dead, so the declaration must be rejected (runtime truth pinned
      # in conditional_validation_spec: the equivalent top-level shape rejects an omitted value regardless
      # of the gate).
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, on: :data, if: :flag, presence: { if: nil }
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "ACCEPTS a DISTINCT-key declaration gate surviving alongside a blank nested override" do
      # Declaration `unless: :flag` + nested `if: nil`: the blank `if:` is dropped, but the distinct
      # `unless: :flag` still gates presence (per-key merge), so `:data` can be omitted when the gate is
      # closed — the tolerance is exercisable and declaration must not reject.
      expect do
        build_axn do
          expects :flag, type: :boolean, default: false
          expects :data, optional: true
          expects :user, on: :data, unless: :flag, presence: { if: nil }
        end
      end.not_to raise_error
    end
  end

  describe "unanswerable-segment rejection" do
    it "rejects a segment that reads through a scalar shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects :baz, on: "payload.bar", type: Integer
        end
      end.to raise_error(ArgumentError, /:baz.*can never resolve.*baz/m)
    end

    it "rejects a multi-segment path off a declared-scalar explicit parent" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :bar, on: :payload, type: String
          expects :b, on: "bar.a", type: Integer
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    it "rejects an unanswerable segment via a dotted on: path" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :bar, on: :payload, type: String
          expects :id, on: "payload.bar", type: Integer
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    it "rejects when a LATER type declaration makes an EARLIER subfield unanswerable" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :baz, on: "payload.bar", type: Integer
          expects :bar, on: :payload, type: String
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    it "rejects regardless of the subfield's own optional:/default: (dead machinery)" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects :baz, on: "payload.bar", type: Integer, optional: true, default: 1
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    # Legal reader patterns — the false-positives that killed the pulled detector:
    it "accepts a method-answerable segment on a scalar (Array#count)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :items, on: :payload, type: Array
          expects :count, on: :items, type: Integer
        end
      end.not_to raise_error
    end

    it "accepts String#length on a scalar shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects :length, on: "payload.bar", type: Integer
        end
      end.not_to raise_error
    end

    it "accepts segments through unknown classes and model parents (optimistic)" do
      data_klass = Class.new { def self.fetch(_id) = nil }
      stub_const("OpaqueThing", data_klass)
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, type: OpaqueThing
          expects :b, on: "thing.a", type: Integer, optional: true
          expects :company, on: :payload, model: { klass: OpaqueThing, finder: :fetch }, optional: true
          expects :y, on: "company.x", type: Integer, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a subclass-answerable segment on an abstract Numeric type (optimistic)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :num, on: :payload, type: Numeric
          expects :bit_length, on: :num, type: Integer
        end
      end.not_to raise_error
    end

    it "accepts a DateTime-specific segment on a type: Date declaration (optimistic)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :when, on: :payload, type: Date
          expects :hour, on: :when, type: Integer
        end
      end.not_to raise_error
    end
  end

  describe "dead nil-tolerance through a model parent" do
    it "rejects a nil-tolerant model parent with an unrescued required descendant" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.to raise_error(ArgumentError, /:company is declared nil-tolerant.*model/m)
    end

    it "accepts a defaulted required descendant (value-level defaults make it satisfiable)" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: "x"
        end
      end.not_to raise_error
    end

    it "accepts a record-supplying default on the model itself" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true, default: -> { DeadCo.new(id: 9) }
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end

    it "accepts a defaulted explicit id sibling declared FIRST" do
      expect do
        build_axn do
          expects :company_id, type: Integer, default: 42
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end

    it "accepts a model SUBFIELD with a defaulted id sibling subfield" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :company_id, on: :payload, type: Integer, default: 42
          expects :company, on: :payload, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end

    it "accepts a nil-tolerant ancestor above a model subfield rescued by a defaulted id sibling" do
      # The sibling `company_id` value-level default supplies the lookup token at read time
      # (ContractForSubfields.resolve_model_via_sibling_id), so `:company` resolves and `:name` reads
      # off the record — which means the nil-tolerant `:meta` ancestor is genuinely exercisable and
      # must NOT be rejected. call(payload: {}) succeeds at runtime.
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end

    context "sibling-id credit is limited to the model route at a merged node" do
      it "rejects when a merged NON-model route on the same node needs the raw wire value" do
        # `:company` and `"meta.company"` merge onto one node: a model route (rescued by the id) AND a
        # required non-model route. The id default supplies only the model lookup token; the non-model
        # route reads the raw wire value the id can't provide, so `:meta`'s tolerance is still dead
        # (call(payload: {}) fails the non-model route). Declaration order matters — model + sibling
        # before the non-model route.
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, type: Integer, default: 42
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :company, on: "payload.meta", type: DeadCo, as: :meta_company
          end
        end.to raise_error(ArgumentError, /:meta is declared nil-tolerant/)
      end

      it "accepts when the merged non-model route is itself nil-tolerant (optional:)" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, type: Integer, default: 42
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :company, on: "payload.meta", type: DeadCo, optional: true, as: :meta_company
          end
        end.not_to raise_error
      end

      it "accepts a nil-tolerant merged non-model route even under a required grandchild" do
        # The node carries a model route (rescued by the defaulted `:company_id` sibling) AND a
        # nil-tolerant non-model route, with a REQUIRED grandchild `:name`. The sibling id rescues the
        # whole node: the model route resolves the record which answers `:name`, and the optional
        # non-model route tolerates nil — so neither tolerance is dead. The per-config loop must skip
        # ANY nil-accepted config at the rescued node, not only the model route.
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, type: Integer, default: 42
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :company, on: "payload.meta", type: DeadCo, optional: true, as: :meta_company
            expects :name, on: :company, type: String
          end
        end.not_to raise_error
      end
    end

    context "a blank-literal id default is never a lookup token" do
      it "rejects an optional blank <field>_id default as a model rescue" do
        # A blank id default ("") is credited usable for the id field's OWN omission, but the model
        # resolver blank-guards the id (Model#derive_value returns nil on a blank token), so it can
        # never resolve the record — the tolerance on the omitted model (and its :meta ancestor) is
        # dead.
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, optional: true, default: ""
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String
          end
        end.to raise_error(ArgumentError, /declared nil-tolerant/)
      end

      it "accepts a non-blank literal id default (42)" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, type: Integer, default: 42
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String
          end
        end.not_to raise_error
      end

      it "accepts a Proc id default (unknowable → optimistic)" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, allow_nil: true
            expects :company_id, on: :meta, default: -> { 42 }
            expects :company, on: :meta, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String
          end
        end.not_to raise_error
      end
    end
  end

  describe "two defaults on one merged wire node are accepted, except a crossing descendant (PRO-3068)" do
    # Two differently-defaulted readers over one wire slot is a coherent contract: each reader resolves its
    # own default on its own read path, nothing is written to the wire, and `node_optional?`'s satisfiability
    # credit gets MORE accurate (both routes rescue an omitted slot, not just one).
    it "accepts two literal defaults on the same merged wire node, each reader resolving its own" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash, optional: true
        expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
        expects :count, on: "payload.meta", default: "", optional: true
        exposes :data
        define_method(:call) { expose(:data, { meta_count:, count: }) }
      end

      result = klass.call(payload: { meta: {} })

      expect(result).to be_ok
      expect(result.data).to eq(meta_count: 42, count: "")
    end

    it "resolves the same per-route defaults regardless of which route is declared first" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash, optional: true
        expects :count, on: "payload.meta", default: "", optional: true
        expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
        exposes :data
        define_method(:call) { expose(:data, { meta_count:, count: }) }
      end

      result = klass.call(payload: { meta: {} })

      expect(result).to be_ok
      expect(result.data).to eq(meta_count: 42, count: "")
    end

    it "accepts two Proc defaults on the same merged wire node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: -> { 1 }, optional: true
          expects :count, on: "payload.meta", default: -> { 2 }, optional: true
        end
      end.not_to raise_error
    end

    # What still stands: a descendant reading DOWN through that node names neither route (PRO-3068).
    it "rejects a descendant that crosses a doubly-defaulted merged node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: { a: 1 }, optional: true, type: Hash
          expects :count, on: "payload.meta", default: { a: 2 }, optional: true, type: Hash
          expects :a, on: "payload.meta.count", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "payload\.meta\.count"/)
    end

    # Rounds out the boundary alongside the two-default and zero-default cases above/below: a merged node's
    # default count (0, 1 or 2) is never itself a reason to reject, now that each route resolves its own.
    it "accepts a merged node where only one route carries a default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: "payload.meta", default: 5, optional: true
          expects :count, on: :meta, as: :meta_count, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a merged node where neither route carries a default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: "payload.meta", optional: true
          expects :count, on: :meta, as: :meta_count, optional: true
        end
      end.not_to raise_error
    end
  end

  describe "an ambiguous crossing (PRO-3068)" do
    # A dotted tail addresses the wire NODE; where two routes merged onto it, the reference names neither,
    # and `configs.first` settles it by declaration order.
    it "rejects a dotted on: whose tail crosses a node with two reader names" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz".*:b1 and :b2/m)
    end

    it "rejects it in the other declaration order too" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "rejects when the crossing is declared BEFORE the second route completes the merge" do
      # check! re-scans the whole candidate tree, so the later declaration that creates the ambiguity is
      # caught even though the crossing reference was legal when it was written.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :src, on: "foo.bar.baz", optional: true
          expects :baz, on: :bar, as: :b2, type: Hash
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "rejects even when no route carries a transform" do
      # The defect is the ambiguous REFERENCE, not an observed divergence: routes that agree today diverge
      # the moment one gains a preprocess:, and two Procs could never be compared anyway.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash
          expects :src, on: "foo.bar.baz", optional: true
        end
      end.to raise_error(ArgumentError, /reads through wire path "foo\.bar\.baz"/)
    end

    it "accepts a descendant that anchors on the route it means" do
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash, preprocess: ->(h) { h.merge(src: "one") }
          expects :baz, on: :bar, as: :b2, type: Hash, preprocess: ->(h) { h.merge(src: "two") }
          expects :src, on: :b2, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a dotted on: rooted at the route's own reader" do
      # `on: "b2.deeper"` names route 2 at the root; the tail below it is implicit, so nothing is unnamed.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", as: :b1, type: Hash
          expects :baz, on: :bar, as: :b2, type: Hash
          expects :src, on: "b2.deeper", optional: true
        end
      end.not_to raise_error
    end

    it "accepts a tail over an implicit intermediate" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :count, on: "payload.meta", type: Integer, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a tail over a declared single-route node" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :count, on: "payload.meta", type: Integer, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a crossing of a node whose routes share ONE reader name" do
      # A confirmation companion beside the author's own same-named declaration is two configs on one node,
      # but both answer to :password_confirmation — dispatch resolves by the reader-owner rule
      # (SubfieldTree.yields_reader_name?), which is order-independent, so nothing is ambiguous.
      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :password, on: :bar, type: Hash, confirmation: true
          expects :password_confirmation, on: "foo.bar", type: Hash
          expects :src, on: "foo.bar.password_confirmation", optional: true
        end
      end.not_to raise_error
    end

    it "accepts an ambient crossing, which resolves by recipe rather than through a route" do
      # An ambient config never enters the shared tree, so resolve_parent reads the `on:` root through its
      # reader and digs every tail segment raw — no route's reader is ever picked.
      expect do
        build_axn do
          expects :meta, on: :ambient_context, type: Hash
          expects :thing, on: "ambient_context.meta", as: :a1, type: Hash, optional: true
          expects :thing, on: :meta, as: :a2, type: Hash, optional: true
          expects :leaf, on: "ambient_context.meta.thing", optional: true
        end
      end.not_to raise_error
    end
  end

  # A top-level `expects` never carries an `on:`, so it looks like it can contradict nothing. It can:
  # an explicit top-level declaration OUTRANKS an explicit subfield of the same name
  # (SubfieldTree.reader_rank), so it takes the reader over and every subfield anchored on that name
  # RE-ANCHORS onto the new root. That is the one move a top-level declaration has, and it can strand a
  # subfield under a parent that cannot answer it, under a map, or under a tolerance nothing rescues.
  # (`_reject_duplicate_fields!` blocks a repeated TOP-LEVEL name, so the takeover is always
  # top-level-over-subfield.)
  describe "a top-level expects that re-anchors an existing subfield (PRO-3169)" do
    it "rejects a re-anchor onto a parent that cannot answer the segment" do
      # Before this ran here, the contract declared cleanly and was unsatisfiable for EVERY input:
      # `counts: "hi"` fails "N can't be blank", `counts: {n: 5}` fails "Counts is not a String" — while
      # the emitted schema advertised `counts` as a plain string and dropped `:n` outright.
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :n, on: :counts, type: Integer
          expects :counts, type: String
        end
      end.to raise_error(ArgumentError, /subfield :n \(on :counts\) can never resolve.*declared String/m)
    end

    it "rejects a re-anchor onto an Array parent" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :n, on: :counts, type: Integer
          expects :counts, type: Array
        end
      end.to raise_error(ArgumentError, /can never resolve.*declared Array/m)
    end

    it "rejects a re-anchor onto a map, the slice PRO-3165 already closed" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :n, on: :counts, type: Integer
          expects :counts, type: Hash, of: { values: Integer }
        end
      end.to raise_error(ArgumentError, /names the key :n of :counts, which declares `of:` on a Hash/)
    end

    it "rejects a re-anchor onto a nil-tolerant parent whose child nothing rescues" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :n, on: :counts, type: Integer
          expects :counts, type: Hash, allow_nil: true
        end
      end.to raise_error(ArgumentError, /:counts is declared nil-tolerant.*:n is required/m)
    end

    it "rejects a re-anchor that pulls a subfield OUT of the ambient subtree onto a scalar root" do
      # `on:` roots at ambient only while the reader-owner index says so. A top-level declaration of that
      # name takes the reader over, so `:ip` stops being an ambient subfield and becomes an ordinary one
      # on a String root — caught by the shared tree, with no ambient-scoped check involved.
      expect do
        build_axn do
          expects :request, on: :ambient_context, type: Hash
          expects :ip, on: :request, type: String
          expects :request, type: String
        end
      end.to raise_error(ArgumentError, /subfield :ip \(on :request\) can never resolve/)
    end

    it "accepts a re-anchor onto a parent that CAN still answer the subfield, and re-points the read" do
      # The mechanism the whole seam rests on, pinned against the runtime rather than asserted: the two
      # candidate parents disagree, so which value `:n` resolves to says where it is anchored. It reads
      # the TOP-LEVEL root (99), not the `payload.counts` it was originally declared on (1).
      action = nil
      expect do
        action = build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :n, on: :counts, type: Integer
          expects :counts, type: Hash
          exposes :seen
          def call = expose(seen: n)
        end
      end.not_to raise_error

      expect(action.call(payload: { counts: { n: 1 } }, counts: { n: 99 }).seen).to eq(99)
    end

    it "accepts a re-anchor onto a model: route, whose record is never statically refutable" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :counts, on: :payload, type: Hash
          expects :name, on: :counts, type: String
          expects :counts, model: "DeadCo"
        end
      end.not_to raise_error
    end

    it "leaves a top-level declaration that takes over no reader alone" do
      # The checks are asked over the WHOLE candidate tree, so every unrelated top-level field is
      # re-judged at this seam too. None of these declares a contradiction, and none may start to.
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :kid, on: :payload, type: Integer
          expects :other, allow_nil: true
          expects :maybe, allow_blank: true
          expects :extra, type: Hash, optional: true
          expects :counts, type: Hash, of: { values: Integer }
          expects :label, type: String
        end
      end.not_to raise_error
    end

    it "does not re-anchor a dotted wire segment that merely shares a top-level field's name" do
      # `payload.bar` is a wire key read out of `payload`, not a reader — so a top-level `:bar` is a
      # different node entirely and strands nothing.
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :baz, on: "payload.bar", type: Integer
          expects :bar, type: String
        end
      end.not_to raise_error
    end

    it "runs no check at all when the contract declares no subfield" do
      expect(Axn::Core::Contract::SubfieldContradictions).not_to receive(:check!)
      build_axn do
        expects :payload, type: Hash
        expects :other, allow_nil: true
      end
    end
  end
end
