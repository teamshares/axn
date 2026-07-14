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

  describe "family 1: dead nil-tolerance" do
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

  describe "family 2: unanswerable segments" do
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

  describe "family 3: the model flavor" do
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
  end
end
