# frozen_string_literal: true

RSpec.describe "shape contracts (block syntax for structured fields)" do
  describe "array element members" do
    it "validates a declared member field on each array element" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String
        end
      end

      result = action.call(items: [{ status: "ok" }, { status: 123 }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
      expect(result.exception.message).to match(/status/)
    end

    it "passes when every element's members are valid" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String
        end
      end

      expect(action.call(items: [{ status: "a" }, { status: "b" }])).to be_ok
    end

    it "validates member enum/inclusion per element, reporting the index" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[connected error] }
        end
      end

      result = action.call(items: [{ status: "connected" }, { status: "bogus" }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
    end

    it "does not define a reader for shape members (no single value to bind)" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String
        end
      end

      expect(action.instance_methods).not_to include(:status)
    end
  end

  describe "single structured value (type: Hash)" do
    it "validates the value's members directly, without an element index" do
      action = build_axn do
        expects :payload, type: Hash do
          field :name, type: String
        end
      end

      result = action.call(payload: { name: 123 })
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/name/)
      expect(result.exception.message).not_to match(/element at index/)
    end
  end

  describe "of: Data.define element class" do
    it "validates declared members against each element via reader access" do
      point = Data.define(:x, :y)
      action = build_axn do
        klass = point
        expects :points, type: Array, of: klass do
          field :x, type: Integer
        end
      end

      expect(action.call(points: [point.new(x: 1, y: 2)])).to be_ok

      result = action.call(points: [point.new(x: "nope", y: 2)])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
    end
  end

  describe "nesting" do
    it "recurses into a nested object member" do
      action = build_axn do
        expects :items, type: Array do
          field :config, type: Hash do
            field :region, type: String
          end
        end
      end

      result = action.call(items: [{ config: { region: 1 } }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
      expect(result.exception.message).to match(/region/)
    end

    it "recurses into a nested array-of-objects member" do
      action = build_axn do
        expects :items, type: Array do
          field :endpoints, type: Array do
            field :url, type: String
          end
        end
      end

      result = action.call(items: [{ endpoints: [{ url: "ok" }, { url: 5 }] }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/url/)
    end
  end

  describe "on exposes (outbound)" do
    let(:action) do
      build_axn do
        expects :raw, type: Array
        exposes :items, type: Array do
          field :status, type: String
        end

        def call
          expose :items, raw
        end
      end
    end

    it "validates exposed array element members" do
      result = action.call(raw: [{ status: "ok" }, { status: 9 }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
    end

    it "passes when exposed element members are valid" do
      expect(action.call(raw: [{ status: "ok" }])).to be_ok
    end
  end

  describe "whole-field nil handling" do
    it "skips member validation when the field is nil and allow_nil is set" do
      action = build_axn do
        expects :items, type: Array, allow_nil: true do
          field :status, type: String
        end
      end

      expect(action.call(items: nil)).to be_ok
    end
  end

  describe "container mismatch — defers to TypeValidator, no resolver leak" do
    let(:array_action) do
      build_axn do
        expects :items, type: Array do
          field :status, type: String
        end
      end
    end

    it "defers a nil array value to the type/presence error (not a resolver error)" do
      result = array_action.call(items: nil)
      expect(result).not_to be_ok
      expect(result.exception.message).not_to match(/Unclear how to extract/)
    end

    it "defers a scalar array value to the type error" do
      result = array_action.call(items: "not an array")
      expect(result).not_to be_ok
      expect(result.exception.message).not_to match(/Unclear how to extract/)
      expect(result.exception.message).to match(/Array/)
    end

    it "preserves the element index when an element is a scalar (not extractable)" do
      result = array_action.call(items: [42])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
      expect(result.exception.message).to match(/status/)
      expect(result.exception.message).not_to match(/Unclear how to extract/)
    end

    it "preserves the element index for a nil element" do
      result = array_action.call(items: [nil])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
    end

    it "preserves the element index for an Array element (Array#dig can't take a name)" do
      result = array_action.call(items: [%w[a b]])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
      expect(result.exception.message).not_to match(/no implicit conversion/)
    end

    it "defers a non-Hash value on a Hash-shaped field to the type error" do
      action = build_axn do
        expects :payload, type: Hash do
          field :name, type: String
        end
      end

      result = action.call(payload: [1, 2])
      expect(result).not_to be_ok
      expect(result.exception.message).not_to match(/Unclear how to extract/)
      expect(result.exception.message).to match(/Hash/)
    end
  end

  describe "unsupported member options" do
    %i[sensitive default preprocess].each do |opt|
      it "raises when a member declares #{opt}:" do
        value = opt == :preprocess ? ->(v) { v } : true
        expect do
          build_axn do
            expects :items, type: Array do
              field :secret, type: String, opt => value
            end
          end
        end.to raise_error(ArgumentError, /does not support/)
      end
    end
  end

  describe "declaration-time guards" do
    it "raises when a shape block is declared on a scalar type" do
      expect do
        build_axn do
          expects :name, type: String do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /structured type/)
    end

    it "raises when a shape block is declared with no type" do
      expect do
        build_axn do
          expects :thing do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /structured type/)
    end

    it "raises when a shape block is declared on a Date (scalar) type" do
      expect do
        build_axn do
          expects :when, type: Date do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /structured type/)
    end

    it "raises when a shape block is declared on a union type" do
      expect do
        build_axn do
          expects :thing, type: [Array, String] do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /structured type/)
    end

    it "accepts a shape block combined with on: (kwarg parity) and enforces the members" do
      action = build_axn do
        expects :payload, type: Hash
        expects :dims, on: :payload, type: Hash, optional: true do
          field :width, type: Integer
        end
      end

      expect(action.call(payload: { dims: { width: 3 } })).to be_ok
      expect(action.call(payload: { dims: { width: "wide" } })).not_to be_ok
    end

    it "still enforces the structured-type rule for a shape block under on:" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, type: [Array, String] do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /structured type/)
    end

    it "raises when a shape block is declared across multiple fields" do
      expect do
        build_axn do
          expects :a, :b, type: Array do
            field :x, type: String
          end
        end
      end.to raise_error(ArgumentError, /single field/)
    end
  end
end
