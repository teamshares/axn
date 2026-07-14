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
