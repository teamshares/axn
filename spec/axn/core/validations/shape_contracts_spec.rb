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

  # A shape member compiles through the same _parse_field_validations path as a top-level `expects`
  # field, so it inherits default presence: a declared member is required unless it opts out
  # (`optional:`/`allow_nil:`/`allow_blank:`, or a `:boolean`/`:params` type). This pins that parity.
  describe "default presence (parity with top-level expects)" do
    it "requires a declared member by default — an absent key fails per element" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String
        end
      end

      result = action.call(items: [{ status: "ok" }, { other: "x" }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
      expect(result.exception.message).to match(/status can't be blank/)
    end

    it "opts out of default presence with optional: (an absent member passes)" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, optional: true
        end
      end

      expect(action.call(items: [{ other: "x" }])).to be_ok
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

  # A shape member is read off the element being validated. For Hash keys and Struct/OpenStruct/Data
  # members that read resolves declared data (dig / #to_h) and never invokes a behavioral method. For
  # a non-`Data` PORO reader or an Array method the only way to reach the member is to INVOKE it —
  # the sharp path — so, mirroring a subfield's `method_call:`, it's an explicit per-member opt-in.
  describe "method_call: opt-in for object/Array-method shape members (PRO-2907)" do
    # A plain PORO exposing a reader (no dig/[], not Data) — the canonical sharp shape member.
    let(:poro_class) do
      Class.new do
        attr_reader :status

        def initialize(status) = (@status = status)
      end
    end

    describe "without the flag (safe default)" do
      it "raises MethodCallNotPermittedError reading a non-Data object member (loud, not silent)" do
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String
          end
        end

        result = action.call(items: [poro_class.new("ok")])
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::MethodCallNotPermittedError)
      end

      it "never mutates an element during validation (field :pop over Array elements does not run)" do
        inner = [1, 2, 3]
        action = build_axn do
          expects :items, type: Array do
            field :pop, type: Integer
          end
        end

        result = action.call(items: [inner])
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::MethodCallNotPermittedError)
        expect(inner).to eq([1, 2, 3]) # the gate fires before dispatch — no #pop ever ran
      end
    end

    describe "with method_call: true" do
      it "resolves a non-Data object member by invoking its reader" do
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String, method_call: true
          end
        end

        expect(action.call(items: [poro_class.new("ok")])).to be_ok

        result = action.call(items: [poro_class.new(123)])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/element at index 0/)
        expect(result.exception.message).to match(/status/)
      end

      it "resolves an Array-method member by invoking it" do
        action = build_axn do
          expects :items, type: Array do
            field :length, type: Integer, method_call: true
          end
        end

        expect(action.call(items: [[1, 2, 3], [4, 5]])).to be_ok
      end
    end

    describe "regression: safe members keep working with no flag" do
      it "reads Hash-key members via dig" do
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String
          end
        end

        expect(action.call(items: [{ status: "ok" }])).to be_ok
      end

      it "reads Struct members via dig" do
        struct = Struct.new(:status)
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String
          end
        end

        expect(action.call(items: [struct.new("ok")])).to be_ok
      end

      it "reads OpenStruct members via dig" do
        require "ostruct"
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String
          end
        end

        expect(action.call(items: [OpenStruct.new(status: "ok")])).to be_ok # rubocop:disable Style/OpenStructUse
      end

      it "reads Data members via #to_h (the axn-mcp array-element-shape-over-Data case)" do
        point = Data.define(:status)
        action = build_axn do
          expects :items, type: Array do
            field :status, type: String
          end
        end

        expect(action.call(items: [point.new(status: "ok")])).to be_ok

        result = action.call(items: [point.new(status: 123)])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/element at index 0/)
      end
    end

    # The dispatch gate is carried explicitly by the call site, NOT inferred from whether an action
    # is threaded. This pins that invariant so a future change that threads the action into
    # shape-member validation (e.g. to resolve a Symbol validation arg or if:/unless: against the
    # action, PRO-2881) cannot silently re-permit method dispatch.
    describe "gate is independent of action threading" do
      let(:validator_class) do
        Axn::Validation::Fields.validator_class_for(field: :status, validations: { type: { klass: String } })
      end

      it "raises even when an action IS present, as long as method_call was not permitted" do
        errors = nil
        expect do
          errors = Axn::Validation::Fields.errors_for(
            validator_class, source: poro_class.new("ok"), validations: { type: { klass: String } },
                             action: Object.new, permit_method_call: false
          )
        end.to raise_error(Axn::ContractViolation::MethodCallNotPermittedError)
        expect(errors).to be_nil
      end

      it "resolves when method_call is permitted, action present or not" do
        errors = Axn::Validation::Fields.errors_for(
          validator_class, source: poro_class.new("ok"), validations: { type: { klass: String } },
                           action: Object.new, permit_method_call: true
        )
        expect(errors).to be_empty
      end
    end

    # The documented member contract is duck-typed (#field + #validations). A raw `shape:` supplied
    # with a member object that doesn't implement #method_call must not raise — it defaults to the
    # safe no-dispatch behavior, so existing member objects don't have to grow a new method.
    describe "duck-typed member contract (member without #method_call)" do
      it "treats a member lacking #method_call as not opted in (safe default), no NoMethodError" do
        raw_member = Struct.new(:field, :validations).new(:status, { type: { klass: String } })
        action = build_axn do
          member = raw_member
          expects :items, type: Array, shape: { members: [member], container: Array }
        end

        # A Hash-key member read (safe path) succeeds — proves the member was validated without the
        # missing #method_call raising.
        expect(action.call(items: [{ status: "ok" }])).to be_ok

        result = action.call(items: [{ status: 123 }])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/status/)
      end
    end

    describe "nested shapes inherit the rule at each depth" do
      it "raises for a method-dispatch member nested inside another shape without the flag" do
        klass = poro_class
        action = build_axn do
          inner = klass
          expects :items, type: Array do
            field :point, type: inner do
              field :status, type: String
            end
          end
        end

        result = action.call(items: [{ point: poro_class.new("ok") }])
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::MethodCallNotPermittedError)
      end

      it "resolves a nested method-dispatch member when it opts in" do
        klass = poro_class
        action = build_axn do
          inner = klass
          expects :items, type: Array do
            field :point, type: inner do
              field :status, type: String, method_call: true
            end
          end
        end

        expect(action.call(items: [{ point: poro_class.new("ok") }])).to be_ok

        result = action.call(items: [{ point: poro_class.new(123) }])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/status/)
      end
    end
  end
end
