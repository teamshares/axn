# frozen_string_literal: true

# Malformed-input doctrine matrix (PRO-2883): a caller-supplied value that can't hold the declared
# nested structure — wherever it sits on the chain, whatever pass touches it — must NEVER surface as
# a raw exception (TypeError/NoMethodError/UnextractableError). It reads as ABSENT (see
# FieldResolvers.extract_or_nil), so the malformed value's OWN validation classifies it: a dev-facing
# InboundValidationError, or a user-facing failure when the malformed field is user_facing:.
# Every pass × every chain position; extend this matrix when adding a pass that reads or writes
# nested values.
RSpec.describe "Malformed-input doctrine (PRO-2883)" do
  let(:model) do
    Struct.new(:id, :name) do
      def self.find(id) = new(id, "n")
      def self.name = "MatrixModel"
    end
  end

  # Every failure must settle as a contract error, never a raw exception.
  def expect_contract_settled(result)
    expect(result.exception).to be_a(Axn::InboundValidationError) unless result.ok?
  end

  describe "validation reads" do
    it "malformed root" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: :par, type: String
        def call = nil
      end
      result = action.call(par: "bad")
      expect_contract_settled(result)
      expect(result.exception.message).to include("Par is not a Hash")
    end

    it "malformed intermediate (deep dotted chain)" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a.b", type: String
        def call = nil
      end
      expect_contract_settled(action.call(par: { a: 5 }))
    end

    it "malformed subfield-anchored parent value" do
      action = build_axn do
        expects :par, type: Hash
        expects :a, on: :par, type: Hash
        expects :x, on: :a, type: String
        def call = nil
      end
      expect_contract_settled(action.call(par: { a: "bad" }))
    end
  end

  describe "pre-validation passes" do
    it "coercion over a malformed chain" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a.b", optional: true, coerce: Integer
        def call = nil
      end
      expect_contract_settled(action.call(par: { a: 5 }))
    end

    it "preprocess over a malformed chain" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a.b", optional: true, preprocess: :to_s.to_proc
        def call = nil
      end
      expect_contract_settled(action.call(par: { a: 5 }))
    end

    it "defaults over a malformed chain" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a.b", optional: true, default: 1
        def call = nil
      end
      expect_contract_settled(action.call(par: { a: 5 }))
    end
  end

  describe "model resolution" do
    it "model subfield under a malformed root" do
      m = model
      action = build_axn do
        expects :par, type: Hash
        expects :company, on: :par, model: { klass: m }
        def call = nil
      end
      result = action.call(par: "bad")
      expect_contract_settled(result)
      expect(result.exception.message).to include("Par is not a Hash")
    end

    it "model subfield behind a malformed dotted intermediate" do
      m = model
      action = build_axn do
        expects :par, type: Hash
        expects :company, on: "par.org", model: { klass: m }
        def call = nil
      end
      expect_contract_settled(action.call(par: { org: "bad" }))
    end

    it "model consistency check against a malformed parent" do
      m = model
      action = build_axn do
        expects :par, type: Hash
        expects :company, on: :par, model: { klass: m }, optional: true
        def call = nil
      end
      expect_contract_settled(action.call(par: "bad"))
    end
  end

  describe "settling classification" do
    it "user-facing malformed parent settles as a failure with its own message" do
      action = build_axn do
        expects :par, type: Hash, user_facing: "P must be an object"
        expects :x, on: "par.a", type: String
        def call = nil
      end
      result = action.call(par: "bad")
      expect(result.outcome).to be_failure
      expect(result.error).to eq("P must be an object")
    end

    it "a malformed intermediate produces no misleading nil-strand diagnostic" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a.b", type: String
        def call = nil
      end
      result = action.call(par: { a: 5 })
      expect(result.exception.message).not_to include("is nil")
    end
  end

  describe "exotic-but-valid sources stay working" do
    it "frozen caller hashes (copy-on-write everywhere)" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a", optional: true, default: 1
        exposes :got, optional: true
        def call = expose(got: x)
      end
      expect(action.call(par: { a: {} }.freeze).got).to eq(1)
    end

    it "string-keyed caller hashes (key form preserved)" do
      action = build_axn do
        expects :par, type: Hash
        expects :x, on: "par.a", optional: true, default: 1
        exposes :got, optional: true
        def call = expose(got: x)
      end
      expect(action.call(par: { "a" => { "y" => 2 } }).got).to eq(1)
    end

    it "object (Struct) parents write through setters" do
      holder = Struct.new(:x, :y)
      action = build_axn do
        expects :par, type: holder
        expects :x, on: :par, optional: true, default: 1
        exposes :got, optional: true
        def call = expose(got: x)
      end
      expect(action.call(par: holder.new(nil, 2)).got).to eq(1)
    end
  end
end
