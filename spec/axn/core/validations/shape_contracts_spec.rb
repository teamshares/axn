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
    %i[default preprocess].each do |opt|
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

    # as:/prefix: rename a field's generated reader; a shape member is reader-less, so they are rejected
    # with a shape-member-specific message rather than the generic "Unknown key(s)" a bare validations
    # parse would emit (which would wrongly imply they are never valid keys).
    %i[as prefix].each do |opt|
      it "raises a shape-member-specific (not generic unknown-key) error when a member declares #{opt}:" do
        expect do
          build_axn do
            expects :items, type: Array do
              field :secret, type: String, opt => :renamed
            end
          end
        end.to raise_error(ArgumentError, /shape member `secret` does not support.*reader/m)
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

    # A shape describes what is inside a container, so a raw one that names no members list is malformed. It
    # used to be caught on the first CALL (ShapeValidator refuses a nil members list); it is rejected at
    # declaration now, which is strictly earlier and where every other malformed declaration is answered.
    describe "a raw shape that names no members" do
      def declared_with(shape)
        build_axn { expects :payload, type: Hash, shape: }
      end

      it "rejects an absent members list" do
        expect { declared_with({ container: Hash }) }
          .to raise_error(ArgumentError, /a raw `shape:` must supply `members:`.*do … end/m)
      end

      it "rejects an explicit nil members list on the same terms" do
        expect { declared_with({ members: nil, container: Hash }) }
          .to raise_error(ArgumentError, /a raw `shape:` must supply `members:`/)
      end

      it "names the member carrying a malformed nested shape" do
        nested = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: { klass: Hash }, shape: { container: Hash } })

        expect { declared_with({ members: [nested], container: Hash }) }
          .to raise_error(ArgumentError, /a raw `shape:` at shape member `a` must supply `members:`/)
      end

      # An empty list is a real declaration — pointless, since only the container type then constrains the
      # value, but not axn's business to refuse. It declares and calls cleanly.
      it "accepts an explicitly empty members list" do
        klass = declared_with({ members: [], container: Hash })

        expect(klass.call(payload: { anything: 1 })).to be_ok
        expect(klass.call(payload: "not a hash")).not_to be_ok
      end
    end

    # Everything a stored member carries is read off the caller's object ONCE, at declaration, into axn's own
    # `ShapeConfig` (`Contract#_snapshot_member_attributes!`) — so a duck-typed member is not stored as the
    # caller's object at all, and the two layers that read a member cannot see different things.
    describe "the member snapshot" do
      def declared_with_member(member)
        build_axn do
          expects :payload, type: Hash, shape: { members: [member], container: Hash }

          define_method(:call) { nil } # define_method, not `def`: this is inside a method body
        end
      end

      def stored_member(klass) = klass.internal_field_configs.first.validations[:shape][:members].first

      it "stores axn's own ShapeConfig rather than the caller's object" do
        member = Struct.new(:field, :validations).new(:a, {})
        stored = stored_member(declared_with_member(member))

        expect(stored).to be_a(Axn::Core::Contract::ShapeConfig)
        expect(stored).not_to be(member)
      end

      # A member name is stored as the Symbol every consumer keys it by (`Schema#member_properties` emits
      # `field.to_sym`), exactly as a top-level field's is — so `field "a"` and `field :a` are one member
      # whichever route declared it.
      it "stores a String member name as its Symbol" do
        member = Struct.new(:field, :validations).new("a", {})

        expect(stored_member(declared_with_member(member)).field).to eq(:a)
      end

      # THE reason the canonical copy must be stored: the walk canonicalized a String-keyed bag and then threw
      # the result away with the rest of the snapshot, so the schema omitted the constraint entirely while every
      # call raised `ArgumentError: must supply :klass` from the raw bag — two layers, two answers, neither one
      # the declaration.
      it "validates and reflects a String-keyed member bag as its canonical form" do
        klass = declared_with_member(Struct.new(:field, :validations).new(:a, { "type" => { "klass" => String } }))

        expect(klass.input_schema.dig(:properties, :payload, :properties, :a, :type)).to eq("string")
        expect(klass.call(payload: { a: "x" })).to be_ok
        expect(klass.call(payload: { a: 1 })).not_to be_ok
      end

      it "behaves identically for the Symbol-keyed spelling" do
        klass = declared_with_member(Struct.new(:field, :validations).new(:a, { type: { klass: String } }))

        expect(klass.input_schema.dig(:properties, :payload, :properties, :a, :type)).to eq("string")
        expect(klass.call(payload: { a: "x" })).to be_ok
        expect(klass.call(payload: { a: 1 })).not_to be_ok
      end

      # A member's option containers are detached on exactly the terms a field's are — which the snapshot is what
      # makes true, since the canonical copy is what gets stored.
      it "does not let a mutated inclusion: list widen a declared member's enum" do
        enum = %w[a b]
        klass = declared_with_member(Struct.new(:field, :validations).new(:s, { inclusion: { in: enum } }))
        enum << "c"

        expect(klass.call(payload: { s: "c" })).not_to be_ok
      end

      # The outbound emitter views a gated member "through" a copy of itself (`config.with(validations: …)`), which
      # only axn's own config types answer to — so a duck-typed member carrying a per-validator gate used to raise
      # `NoMethodError: undefined method 'with'` from `output_schema`. Snapshotting it makes the copy axn's own.
      it "reflects an exposes member carrying a per-validator gate, which needs a config copy" do
        member = Struct.new(:field, :validations).new(:a, { type: { klass: Integer, if: :flag } })
        klass = build_axn do
          exposes :payload, type: Hash, shape: { members: [member], container: Hash }

          define_method(:call) { expose(payload: {}) }
        end

        expect(klass.output_schema.dig(:properties, :payload, :properties)).to eq({ a: {} })
      end

      # `#default` is not part of the member grammar — the block form rejects `default:` outright, since a member
      # is reader-less and nothing applies one at runtime. A duck-typed member defining the reader used to have it
      # emitted anyway, which made the schema LIE: it advertised the member as optional with a default, and the
      # omitted call then failed presence validation.
      it "ignores a #default reader, so the schema no longer promises a default nothing applies" do
        klass = declared_with_member(Struct.new(:field, :validations, :default).new(:a, { presence: true }, "dflt"))

        expect(klass.input_schema.dig(:properties, :payload, :properties, :a)).to eq({})
        expect(klass.input_schema.dig(:properties, :payload, :required)).to eq(["a"])
        expect(klass.call(payload: {})).not_to be_ok
      end
    end

    # A declared field's `type:` reaches reflection canonicalized to `{ klass: … }` (the DSL applies
    # TypeValidator's syntactic sugar); a raw `shape:` member's does not — `#field` + `#validations` is the
    # whole member contract, so `type: Hash`, the only spelling anyone writes by hand, arrives at the
    # projection bare. The projection read it as `dig(:type, :klass)` while the layer that DESCRIBES what it
    # emitted read it as either spelling, so reflecting such a member raised
    # `TypeError: #<Class:Hash> does not have #dig method` — naming neither the member nor the option. Both
    # layers now read it through one owner (`Schema.declared_klass`), so the bare spelling reflects as exactly
    # what the canonical one reflects as.
    describe "a member whose type: is spelled bare (no `{ klass: }` bag)" do
      def member(validations) = Axn::Core::Contract::ShapeConfig.new(field: :m, validations:)
      def inner = { members: [Axn::Core::Contract::ShapeConfig.new(field: :x, validations: {})], container: Hash }

      def inbound(validations)
        m = member(validations)
        build_axn { expects :payload, type: Hash, shape: { members: [m], container: Hash } }
      end

      def outbound(validations)
        m = member(validations)
        build_axn do
          exposes :payload, type: Hash, shape: { members: [m], container: Hash }

          define_method(:call) { expose(payload: {}) }
        end
      end

      it "emits the member's own shape rather than raising" do
        klass = inbound({ type: Hash, shape: inner })

        expect(klass.input_schema.dig(:properties, :payload, :properties, :m))
          .to eq({ type: "object", properties: { x: {} } })
      end

      it "emits exactly what the canonical `{ klass: }` spelling emits, inbound and outbound" do
        %i[input_schema output_schema].each do |schema|
          expect(inbound({ type: Hash, shape: inner }).public_send(schema))
            .to eq(inbound({ type: { klass: Hash }, shape: inner }).public_send(schema))
        end
      end

      # The type's OWN members are contributed by the same read, so a bare `type: <Data>` has to reach them
      # too — otherwise the bare spelling would emit a strictly smaller property set than the canonical one.
      it "contributes a bare Data type's members alongside the shape's" do
        klass = inbound({ type: Data.define(:a, :b), shape: inner })

        expect(klass.input_schema.dig(:properties, :payload, :properties, :m, :properties).keys).to eq(%i[a b x])
      end

      # OUTPUT asks a second question of the same option — whether the value provably serializes member-keyed
      # (`shape_serializes_to_object?`) — so the bare spelling must reach that decision as well, including its
      # negative answer: a Data with its own `as_json` may serialize to anything, so its property stays untyped.
      it "leaves an outbound member untyped when its bare type overrides as_json" do
        custom = Class.new(Data.define(:c)) { def as_json(*) = "scalar" }

        expect(outbound({ type: custom, shape: inner }).output_schema.dig(:properties, :payload, :properties))
          .to eq({ m: {} })
        expect(outbound({ type: Hash, shape: inner }).output_schema.dig(:properties, :payload, :properties))
          .to eq({ m: { type: "object", properties: { x: {} } } })
      end
    end

    # The documented member contract is duck-typed (#field + #validations). A raw `shape:` supplied
    # with a member object that doesn't implement #method_call must not raise — it defaults to the
    # safe no-dispatch behavior, so existing member objects don't have to grow a new method.
    # Reflection honors the same two-method contract declaration does: a member implementing only #field and
    # #validations reflects, with every other attribute (#description) treated as absent. Before, such a member
    # declared cleanly and then raised NoMethodError from `input_schema`.
    describe "duck-typed member contract (reflection)" do
      it "reflects a member implementing only #field and #validations" do
        member = Class.new do
          def field = :ok
          def validations = {}
        end.new
        klass = build_axn { expects :p, type: Hash, shape: { members: [member] } }

        expect(klass.input_schema.dig(:properties, :p, :properties)).to eq({ ok: {} })
        expect(klass.output_schema[:properties]).to eq({})
      end

      it "reflects such a member on exposes too" do
        member = Class.new do
          def field = :ok
          def validations = {}
        end.new
        klass = build_axn { exposes :p, type: Hash, shape: { members: [member] } }

        expect(klass.output_schema.dig(:properties, :p, :properties)).to eq({ ok: {} })
      end

      it "still emits a description when the member defines one" do
        member = Class.new do
          def field = :ok
          def validations = {}
          def description = "the ok member"
        end.new
        klass = build_axn { expects :p, type: Hash, shape: { members: [member] } }

        expect(klass.input_schema.dig(:properties, :p, :properties, :ok)).to eq({ description: "the ok member" })
      end
    end

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
