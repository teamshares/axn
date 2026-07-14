# frozen_string_literal: true

RSpec.describe Axn::Reflection::SubfieldContradictions do
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
          expects "meta.id", on: :payload, type: Integer, default: 5
          expects :id, on: "payload.meta", type: Integer
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

  describe "unanswerable-segment rejection" do
    it "rejects a dotted name whose segment reads through a scalar shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.baz", on: :payload, type: Integer
        end
      end.to raise_error(ArgumentError, /"bar\.baz".*can never resolve.*baz/m)
    end

    it "rejects a multi-segment name off a declared-scalar explicit parent" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :bar, on: :payload, type: String
          expects "a.b", on: :bar, type: Integer
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
          expects "bar.baz", on: :payload, type: Integer
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
          expects "bar.baz", on: :payload, type: Integer, optional: true, default: 1
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
          expects "bar.length", on: :payload, type: Integer
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
          expects "a.b", on: :thing, type: Integer, optional: true
          expects :company, on: :payload, model: { klass: OpaqueThing, finder: :fetch }, optional: true
          expects "x.y", on: :company, type: Integer, optional: true
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
            expects "meta.company", on: :payload, type: DeadCo
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
            expects "meta.company", on: :payload, type: DeadCo, optional: true
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
            expects "meta.company", on: :payload, type: DeadCo, optional: true
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

  describe "conflicting defaults rejection (PRO-2901)" do
    it "rejects two literal defaults on the same merged wire node" do
      # The motivating case: `"meta.count"` (on :payload) and `:count` (on :meta, aliased) merge onto the
      # payload.meta.count wire node, each carrying a default. Only one inbound default can win the shared
      # wire key; declaration order — not any principle — would pick it.
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: "", optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
        end
      end.to raise_error(ArgumentError, /conflicting default:.*payload\.meta\.count/m)
    end

    it "names both routes and their defaults in the message" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: "", optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
        end
      end.to raise_error(ArgumentError, /"meta\.count".*on :payload.*default: a String value.*:count.*on :meta.*default: 42/m)
    end

    it "rejects EQUAL literal defaults uniformly (agreement today drifts tomorrow)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: 5, optional: true
          expects :count, on: :meta, as: :meta_count, default: 5, optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:/)
    end

    it "rejects two Proc defaults (uncomparable)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: -> { 1 }, optional: true
          expects :count, on: :meta, as: :meta_count, default: -> { 2 }, optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:.*a callable/m)
    end

    it "names an object default generically without dispatching ANY method on it (side-effect-free)" do
      # An arbitrary object default — even one that responds to :call or overrides #inspect/#respond_to? —
      # must be named by kind without invoking it, so building the declaration error can never run user
      # code (and never mask the conflict message). The stubs raise if any of those methods is dispatched.
      hostile = Class.new do
        def call = raise("must not be called during reflection")
        def inspect = raise("must not be inspected during reflection")
        def respond_to?(*) = raise("must not be queried during reflection")
      end.new
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: hostile, optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:.*a non-literal default/m)
    end

    it "renders a String default by kind, not its (possibly-singleton) #inspect" do
      hostile_string = +"x"
      def hostile_string.inspect = raise("must not be inspected during reflection")
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: hostile_string, optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:.*a String value/m)
    end

    it "rejects a Proc default competing with a literal default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: 5, optional: true
          expects :count, on: :meta, as: :meta_count, default: -> { 1 }, optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:/)
    end

    it "rejects regardless of declaration order" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, as: :meta_count, default: 42, optional: true, type: Integer
          expects "meta.count", on: :payload, default: "", optional: true
        end
      end.to raise_error(ArgumentError, /conflicting default:/)
    end

    # Legal — a single default on a merged node has a principled winner (itself):
    it "accepts a merged node where only one route carries a default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: 5, optional: true
          expects :count, on: :meta, as: :meta_count, optional: true
        end
      end.not_to raise_error
    end

    it "accepts a merged node where neither route carries a default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, optional: true
          expects :count, on: :meta, as: :meta_count, optional: true
        end
      end.not_to raise_error
    end

    it "accepts defaults on DISTINCT wire keys (the suggested fix)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects :count, on: :meta, default: 5, optional: true
          expects :total, on: :meta, default: 42, optional: true
        end
      end.not_to raise_error
    end

    it "does not treat default: nil as a carried default" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, optional: true
          expects "meta.count", on: :payload, default: nil, optional: true
          expects :count, on: :meta, as: :meta_count, default: 5, optional: true
        end
      end.not_to raise_error
    end
  end
end
