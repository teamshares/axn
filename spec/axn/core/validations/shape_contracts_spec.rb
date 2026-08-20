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
      # An absent member is nil, which the member's own `type:` rejects — one error for one defect.
      expect(result.exception.message).to eq("Items element at index 1: status is not a String")

      # The inherited presence check is still enforced: it is what rejects a member that is PRESENT but blank.
      blank = action.call(items: [{ status: "" }])
      expect(blank).not_to be_ok
      expect(blank.exception.message).to match(/status can't be blank/)
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

    # Axn's own validators accept a direct value in place of an options bag (`type: Hash`, `of: Hash`,
    # `validate: ->(v){}`), and the DSL expands it into that bag before storing it. A raw member's bag was
    # canonicalized at the KEY level only, so the bare spelling — the one every author writes — reached the
    # validators and the projection as a Class, which both read as `[:klass]`: the member validated nothing and
    # failed every call, while `of:` took the projection down with it. The member snapshot now applies the same
    # expansion, from the same seam, so a member's bag is a field's bag.
    describe "a member's shorthand validator value" do
      def declared_with(validations)
        member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations:)
        build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
      end

      def property(klass) = klass.input_schema.dig(:properties, :payload, :properties, :m)

      def stored(klass) = klass.internal_field_configs.first.validations[:shape][:members].first.validations

      it "stores `type: Hash` as the bag every consumer reads" do
        expect(stored(declared_with({ type: Hash }))).to eq({ type: { klass: Hash } })
      end

      it "validates `type: Hash`, which used to fail every call with `must supply :klass`" do
        klass = declared_with({ type: Hash })

        expect(klass.call(payload: { m: { a: 1 } })).to be_ok
        expect(klass.call(payload: { m: "nope" }).exception).to be_a(Axn::InboundValidationError)
        expect(klass.call(payload: { m: "nope" }).exception.message).to match(/m is not a Hash/)
      end

      it "reflects it as exactly what the `{ klass: }` spelling reflects, inbound and outbound" do
        %i[input_schema output_schema].each do |schema|
          expect(declared_with({ type: Hash }).public_send(schema))
            .to eq(declared_with({ type: { klass: Hash } }).public_send(schema))
        end
      end

      # `of:` is the same option one layer down, and it was worse off: the projection reads it as a bag in three
      # places, so a bare one raised `ArgumentError: odd number of arguments for Hash` (a Class asked for
      # `[:klass]`) from `input_schema` — before any call could reach the "must supply :klass" the runtime had
      # waiting for it.
      it "projects and validates a bare `of:`, which used to take the projection down" do
        klass = declared_with({ type: Array, of: Hash })

        expect(property(klass)).to eq({ type: "array", items: { type: "object" } })
        expect(klass.call(payload: { m: [{ a: 1 }] })).to be_ok
        expect(klass.call(payload: { m: [1] }).exception.message).to match(/element at index 0 is not a Hash/)
      end

      # A member carrying BOTH a bare `type:` and a nested `shape:` is the corner the projection read as a bag
      # unconditionally: `TypeError: #<Class:Hash> does not have #dig method`, naming neither the member nor the
      # option, and taking `input_schema` (and so `Axn::Tools.validate_contracts!`) with it.
      it "projects a bare `type:` carrying a nested shape, and validates through it" do
        inner = Axn::Core::Contract::ShapeConfig.new(field: :n, validations: { type: String })
        klass = declared_with({ type: Hash, shape: { members: [inner], container: Hash } })

        expect(property(klass)).to eq({ type: "object", properties: { n: { type: "string" } }, required: ["n"] })
        expect(klass.call(payload: { m: { n: "x" } })).to be_ok
        expect(klass.call(payload: { m: { n: 1 } }).exception.message).to match(/m n is not a String/)
      end

      # The expansion runs after the KEYS are canonicalized, which is what lets a String-keyed bag reach the
      # expander as the bag it is: `validate:`'s expander rejects a Hash carrying no callable, and reading this
      # one before its keys were canonical would reject a declaration that supplies one.
      it "expands a String-keyed bag by its canonical keys" do
        klass = declared_with({ "validate" => { "with" => ->(v) { "must be 1" unless v == 1 } } })

        expect(klass.call(payload: { m: 1 })).to be_ok
        expect(klass.call(payload: { m: 2 }).exception.message).to match(/m must be 1/)
      end

      # Reached through the same expansion, so the misuse it catches is now caught where every other malformed
      # declaration is. It used to declare cleanly and raise the same ArgumentError on every call.
      it "rejects a `validate:` Hash carrying no callable at declaration" do
        expect { declared_with({ validate: { inclusion: { in: [1] } } }) }
          .to raise_error(ArgumentError, /`validate:` expects a callable/)
      end

      # `model:` is the one shorthand a member has no meaning for — it resolves a record and exposes a
      # companion reader, neither of which a reader-less member has — so it is refused on the raw route exactly
      # as the block form refuses it, rather than expanded into a bag that would silently type-check the
      # element in place. Before, it declared cleanly and failed every call with `must supply :klass`.
      it "rejects `model:` at declaration, as the block form does" do
        expect { declared_with({ model: Struct.new(:id) }) }
          .to raise_error(ArgumentError, /shape member `m` does not support model:.*type: Klass/m)
      end

      # `confirmation:` needs a sibling to compare against and a per-member requiredness gate that can name
      # it — neither of which a reader-less member can express, since a member's `if:`/`unless:` resolves
      # against the action rather than the element — so it is refused on the raw route exactly as the block
      # form refuses it, rather than expanded into a validator that raises NoMethodError on every call.
      it "rejects `confirmation:` at declaration, as the block form does" do
        expect { declared_with({ confirmation: true }) }
          .to raise_error(ArgumentError, /shape member `m` does not support confirmation:.*on: :<parent>/m)
      end

      # Expanding a shorthand is only half of what canonicalizing a bag is for: the compatibility guards that
      # read the canonical bag live in the same seam, so a member is held to exactly what a field is held to.
      # `of:` beside a `type:` naming no container is the case with no runtime signal at all — `OfValidator`
      # returns before it inspects anything that is not a container, so on a value the declared `type:` accepts
      # the constraint simply never applies. It declared cleanly and every call succeeded.
      it "rejects `of:` beside a `type:` that is neither Array nor Hash, with the field path's own message" do
        expect { declared_with({ type: String, of: String }) }
          .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [String])")
      end

      # Same guard, the other spelling of the same mistake: with no `type:` at all there is no container to read
      # the constraint against, so the member accepted every value it was declared to constrain.
      it "rejects a bare `of:` with no `type:`, as the field path does" do
        expect { declared_with({ of: String }) }
          .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [])")
      end

      # The constrains-nothing half of the same pair, reached through the expansion (`of: nil` expands to
      # `{ klass: nil }`): it used to declare cleanly and raise `must supply :klass` from `check_validity!` on
      # every call, which is the field path's message arriving at the wrong time and at the wrong person.
      it "rejects `of: nil` at declaration, where it used to raise on every call" do
        expect { declared_with({ type: Array, of: nil }) }
          .to raise_error(ArgumentError, "of: must constrain something — name the contents' class with " \
                                         "`klass:`, what is inside them with `of:`, or their members with " \
                                         "`shape:`")
      end

      # `of: false` is not `of: nil`: it expands to `{ klass: false }`, which NAMES something, so the
      # constrains-nothing check above passes it and `TypeValidator.value_matches?(el, klass: false)` used to
      # raise a bare `TypeError: class or module required` on the first call carrying a non-empty Array. It is
      # the bag grammar's own question — is this a type the runtime can hold a value to? — so it is refused
      # where every bag is judged, and both routes reach it because a member is held to what a field is.
      it "rejects `of: false` at declaration on a member exactly as on a field" do
        message = "of: klass: must name a type — a Class, a union of them, or one of " \
                  ":boolean, :uuid, :params (got a value of class FalseClass)"

        expect { declared_with({ type: Array, of: false }) }.to raise_error(ArgumentError, message)
        expect { build_axn { expects :m, type: Array, of: false } }.to raise_error(ArgumentError, message)
      end

      # A bare `type:` naming a LIST is expanded around a copy of that list, since the detach pass runs first —
      # so the stored contract is axn's, exactly as for a field.
      it "detaches a bare `type:` list, so mutating it cannot widen a declared member" do
        types = [String]
        klass = declared_with({ type: types })
        types << Integer

        expect(stored(klass)).to eq({ type: { klass: [String] } })
        expect(klass.call(payload: { m: "x" })).to be_ok
        expect(klass.call(payload: { m: 1 })).not_to be_ok
      end
    end

    # A member's nested `shape:` is a shape declared by hand exactly as a field's is, so it is held to the
    # field's own derivation and container check — at every level the declaration walk descends through.
    # Before, the walk recursed past both: a hand-written nested shape (the natural spelling for a raw member)
    # reached ShapeValidator with a nil container and raised a bare `TypeError: class or module required` on
    # EVERY call, naming neither the member nor the option, while the block form derived one and worked.
    describe "a member's nested `shape:`" do
      def declared_with(validations)
        member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations:)
        build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
      end

      def nested(klass, depth = 1)
        node = klass.internal_field_configs.first.validations[:shape]
        depth.times { node = node[:members].first.validations[:shape] }
        node
      end

      let(:leaf) { Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: { type: String }) }

      it "derives the container from the member's own `type:`, where every call used to raise TypeError" do
        klass = declared_with({ type: Hash, shape: { members: [leaf] } })

        expect(nested(klass)[:container]).to eq(Hash)
        expect(klass.call(payload: { m: { leaf: "x" } })).to be_ok
        expect(klass.call(payload: { m: { leaf: 1 } }).exception.message).to match(/m leaf is not a String/)
      end

      # The container a member's nested shape gets is the one the block form gives the same declaration —
      # verified by comparing the stored node against the route that already derived it (a block-form member
      # carrying a raw `shape:` kwarg, which reaches the field path's derivation through `_parse_field_configs`).
      it "stores the node the block form stores for the same declaration" do
        raw = declared_with({ type: Hash, shape: { members: [leaf] } })
        via_block = build_axn do
          member_shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: { type: String })] }
          expects :payload, type: Hash do
            field :m, type: Hash, shape: member_shape
          end
        end

        expect(nested(raw)[:container]).to eq(nested(via_block)[:container])
        expect(nested(raw)[:members].map(&:to_h)).to eq(nested(via_block)[:members].map(&:to_h))
      end

      # An Array-typed member's `shape:` distributes over its ELEMENTS, so it is canonicalized into the
      # member's own `of:` bag (PRO-3166) rather than staying at the member. The bag names no element class,
      # so the shape it carries gates on nothing — the ANY_CONTAINER sentinel — and its members are read off
      # each element exactly as the distributing spelling read them.
      it "folds an Array-typed member's shape into its of: bag, gating on nothing" do
        klass = declared_with({ type: Array, shape: { members: [leaf] } })
        member = klass.internal_field_configs.first.validations[:shape][:members].first

        expect(member.validations[:shape]).to be_nil
        expect(member.validations.dig(:of, :container)).to eq(Array)
        expect(member.validations.dig(:of, :shape, :container)).to eq(Axn::Internal::ShapeGraph::ANY_CONTAINER)
        expect(klass.call(payload: { m: [{ leaf: "x" }] })).to be_ok
        expect(klass.call(payload: { m: [{ leaf: 1 }] })).not_to be_ok
      end

      # The walk recurses, so every level is a member of some shape and gets the same treatment: a two-level
      # nested shape behaves exactly as a one-level one.
      it "derives at every nesting level, not just the first" do
        deep = Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: { type: Hash, shape: { members: [leaf] } })
        klass = declared_with({ type: Hash, shape: { members: [deep] } })

        expect(nested(klass, 1)[:container]).to eq(Hash)
        expect(nested(klass, 2)[:container]).to eq(Hash)
        expect(klass.call(payload: { m: { deep: { leaf: "x" } } })).to be_ok
      end

      it "rejects a non-class nested `container:` at declaration, with the field path's own message" do
        expect { declared_with({ type: Hash, shape: { members: [], container: :junk } }) }
          .to raise_error(ArgumentError, /a shape's `container:` must be a class \(got :junk\)/)
      end

      it "rejects one nested two levels down just the same" do
        deep = Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: { type: Hash, shape: { members: [], container: :junk } })

        expect { declared_with({ type: Hash, shape: { members: [deep], container: Hash } }) }
          .to raise_error(ArgumentError, /a shape's `container:` must be a class \(got :junk\)/)
      end

      # Derivation reports the field path's declaration error when there is nothing structured to derive from,
      # rather than storing a nil container for the first call to trip over.
      it "raises when the member declares no structured `type:` to derive from" do
        expect { declared_with({ shape: { members: [leaf] } }) }
          .to raise_error(ArgumentError, /a shape block requires a single structured type:/)
      end

      # The declared classes are the CALLER's, and rendering the LIST would dispatch each one's own `inspect`
      # — so a class whose `inspect` raises would replace this declaration error with its own exception,
      # which outside StandardError escapes every rescue meant to settle it. Named natively instead, through
      # the same seam the `of:` container refusal uses.
      it "raises the declaration error even when a declared type's own inspect raises" do
        stub_const("RaisingInspectType", Class.new { def self.inspect = raise("boom from inspect") })

        expect { declared_with({ type: [RaisingInspectType, Hash], shape: { members: [leaf] } }) }
          .to raise_error(ArgumentError,
                          "a shape block requires a single structured type: (Array, Hash, or a class) — " \
                          "got [RaisingInspectType, Hash]")
      end

      # A token that is neither a class nor a pseudo-type has no name to read, so it is described by its own
      # class rather than by running its `inspect` — the one place the rendering diverges from the list's.
      it "describes a non-class token by its class instead of inspecting it" do
        expect { declared_with({ type: ["Hash", Hash], shape: { members: [leaf] } }) }
          .to raise_error(ArgumentError,
                          "a shape block requires a single structured type: (Array, Hash, or a class) — " \
                          "got [a value of class String, Hash]")
      end

      # The `container:` a raw `shape:` supplies is the CALLER's object, and `container == Array` dispatches
      # that object's own `==` — so a container answering true takes the distributing branch and validates its
      # members per ELEMENT instead of off the value itself. `::Array` is the receiver of the identity test,
      # so only its own `equal?` runs, and this Array subclass is validated as the single value it declares.
      it "does not let a container answering `==` divert the value into the per-element branch" do
        liar = Class.new(Array) do
          def self.==(_other) = true
        end
        stub_const("LyingContainer", liar)
        value = LyingContainer.new
        value << { leaf: 1 }

        # Hoisted to a local: `build_axn` class_evals its block, so `self` there is the action class and the
        # `leaf` helper above is out of reach.
        member = leaf
        action = build_axn { expects :rows, type: LyingContainer, shape: { members: [member], container: LyingContainer } }

        # Read off the value itself (unreadable, since an Array answers no named key) — never "element at
        # index 0: leaf is not a String", which is what the diverted branch reports.
        expect(action.call(rows: value).exception.message).to eq("Rows leaf could not be read (got LyingContainer)")
      end

      it "leaves an explicit nested `container:` exactly as declared" do
        klass = declared_with({ type: Hash, shape: { members: [leaf], container: Hash } })

        expect(nested(klass)[:container]).to eq(Hash)
        expect(klass.call(payload: { m: { leaf: "x" } })).to be_ok
      end

      # A container comes from the ENCLOSING member's `type:`, so it belongs to the position rather than to the
      # node: one nested shape object reused by two members with different types needs a different container in
      # each place. The walk's memo hands both members one copy, so the derivation detaches before it writes.
      it "gives one shared nested shape the container each position calls for" do
        shared = { members: [leaf] }
        klass = build_axn do
          node = shared
          expects :payload, type: Hash, shape: { container: Hash, members: [
            Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Hash, shape: node }),
            Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { type: Array, shape: node }),
          ] }
        end
        members = klass.internal_field_configs.first.validations[:shape][:members]
        # The Array-typed position's copy is folded into its `of:` bag, where the container it calls for is
        # the element's rather than the member's — so the two positions still hold ONE shared node to two
        # different containers, which is what the detach-before-write buys.
        containers = members.map { |m| (m.validations[:shape] || m.validations.dig(:of, :shape))[:container] }

        expect(containers).to eq([Hash, Axn::Internal::ShapeGraph::ANY_CONTAINER])
        expect(shared.key?(:container)).to be(false)
        expect(klass.call(payload: { a: { leaf: "x" }, b: [{ leaf: "y" }] })).to be_ok
      end

      it "derives on the outbound route too" do
        klass = build_axn do
          inner = Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: { type: String })
          member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: Hash, shape: { members: [inner] } })
          exposes :payload, type: Hash, shape: { members: [member], container: Hash }
          define_method(:call) { expose(payload: { m: { leaf: "x" } }) }
        end

        expect(klass.external_field_configs.first.validations[:shape][:members].first.validations[:shape][:container]).to eq(Hash)
        expect(klass.call).to be_ok
      end
    end

    # A raw member's bag never passes `_partition_field_options`, so nothing had ever held its KEYS to a
    # grammar: a typo declared cleanly and raised `Unknown validator: 'TpyeValidator'` on every call, naming a
    # class the author never wrote and neither the member nor the option, where the same typo on a field is
    # refused at declaration. The allowed set is derived from the field path's own (KNOWN_VALIDATION_KEYS)
    # unioned with ActiveModel's shared options, which is what a raw bag reaches `validates` as.
    describe "a member's option keys" do
      def declared_with(validations)
        member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations:)
        build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
      end

      def declared_two_deep(validations)
        leaf = Axn::Core::Contract::ShapeConfig.new(field: :deep, validations:)
        declared_with({ type: Hash, shape: { members: [leaf] } })
      end

      it "rejects a typo at declaration, naming the member and the key" do
        expect { declared_with({ tpye: String }) }
          .to raise_error(ArgumentError, /Unknown key\(s\) :tpye in the validations of shape member `m`/)
      end

      it "rejects one two levels down just the same" do
        expect { declared_two_deep({ tpye: String }) }
          .to raise_error(ArgumentError, /Unknown key\(s\) :tpye in the validations of shape member `deep`/)
      end

      it "rejects a key that is not a Symbol at all" do
        expect { declared_with({ 1 => String }) }
          .to raise_error(ArgumentError, /Unknown key\(s\) .* in the validations of shape member `m`/)
      end

      # The verdict is not the caller's to decide: a key that is not a Symbol is unknown by construction, so
      # one answering `hash`/`eql?` as `:type` cannot pass itself off as a recognized option — and its own
      # `to_s` is not run to report it, since that is caller code running while its error is built.
      it "refuses a key that claims to be a recognized one, naming it by class" do
        lying = Class.new do
          def hash = :type.hash
          def eql?(other) = other.equal?(:type)
          def to_s = raise(NotImplementedError)
        end

        expect { declared_with({ lying.new => String }) }
          .to raise_error(ArgumentError, /Unknown key\(s\) a name of class .* in the validations of shape member `m`/)
      end

      # A member's non-validation options are attributes of the member itself, so the same names in its
      # validations bag are in the wrong slot — the message says where they belong.
      %i[optional sensitive user_facing method_call description].each do |opt|
        it "rejects #{opt}: in the bag, pointing at where a member carries it" do
          expect { declared_with({ opt => true, type: String }) }
            .to raise_error(ArgumentError, /Unknown key\(s\) :#{opt} .*attributes of the member ITSELF/m)
        end
      end

      # The two the block form already refuses with a REASON keep that reason on this route: an author who
      # wrote `default:` has a different problem from one who wrote `tpye:`.
      %i[default preprocess].each do |opt|
        it "gives #{opt}: the block form's own reason rather than the unknown-key message" do
          expect { declared_with({ opt => true, type: String }) }
            .to raise_error(ArgumentError, %r{shape member `m` does not support #{opt}: \(shape blocks declare validation/schema only\)})
        end
      end

      %i[as prefix].each do |opt|
        it "gives #{opt}: the reader-less reason" do
          expect { declared_with({ opt => :renamed, type: String }) }
            .to raise_error(ArgumentError, /shape member `m` does not support #{opt}:.*reader-less/m)
        end
      end

      # `coerce:` is field-only (it resolves a coerced value onto a reader a member has not got), and the block
      # form refuses it whichever way it is spelled. The raw route refused neither: a top-level `coerce:`
      # reached ActiveModel as a validator, and the bag spelling was accepted and silently did nothing.
      it "refuses a top-level `coerce:`" do
        expect { declared_with({ coerce: Integer }) }
          .to raise_error(ArgumentError, /coerce: is not supported on a shape member/)
      end

      it "refuses the `type: { coerce: true }` spelling, which used to be silently inert" do
        expect { declared_with({ type: { klass: Integer, coerce: true } }) }
          .to raise_error(ArgumentError, /coerce: is not supported on a shape member/)
      end

      it "refuses one two levels down" do
        expect { declared_two_deep({ coerce: Integer }) }
          .to raise_error(ArgumentError, /coerce: is not supported on a shape member/)
      end

      it "leaves `coerce: false` the legal no-op it is on a field" do
        expect(declared_with({ type: { klass: Integer, coerce: false } }).call(payload: { m: 1 })).to be_ok
      end

      it "still accepts every validation a member legitimately carries" do
        expect(declared_with({ type: String }).call(payload: { m: "x" })).to be_ok
        expect(declared_with({ type: Array, of: String }).call(payload: { m: ["x"] })).to be_ok
        expect(declared_with({ presence: true }).call(payload: { m: "x" })).to be_ok
        expect(declared_with({ inclusion: { in: %w[x] } }).call(payload: { m: "x" })).to be_ok
        expect(declared_with({ validate: ->(v) { "no" unless v == "x" } }).call(payload: { m: "x" })).to be_ok
      end

      # ActiveModel's own shared options ride a `validates` call without being validators, and a raw bag
      # reaches `validates` verbatim — so they work on this route today and refusing them would reject a legal
      # declaration. They are unioned in from AM's own list rather than listed again.
      it "accepts ActiveModel's shared options, which apply on this route" do
        klass = declared_with({ type: String, allow_blank: true })

        expect(klass.call(payload: { m: "" })).to be_ok
        expect(declared_with({ type: String, strict: true }).call(payload: { m: "x" })).to be_ok
        expect(declared_with({ type: String, if: -> { false } }).call(payload: { m: 1 })).to be_ok
      end

      it "leaves a member's own attributes alone — they were never bag keys" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: String }, sensitive: true, user_facing: true)
        klass = build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
        stored = klass.internal_field_configs.first.validations[:shape][:members].first

        expect([stored.sensitive, stored.user_facing, stored.validations.keys]).to eq([true, true, [:type]])
        expect(klass.call(payload: { m: "x" })).to be_ok
      end

      # The block form reaches this bag only through `_partition_field_options`, which has always refused an
      # unknown key — and it accepts the member options the raw route cannot take in a bag.
      it "leaves the block form's own verdicts unchanged" do
        expect { build_axn { expects(:payload, type: Hash) { field :m, tpye: String } } }
          .to raise_error(ArgumentError, /Unknown key\(s\) :tpye in field declaration/)
        expect(build_axn { expects(:payload, type: Hash) { field :m, type: String, optional: true, sensitive: true } }
                 .call(payload: { m: "x" })).to be_ok
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
        klass = build_axn { expects :par, type: Hash, shape: { members: [member] } }

        expect(klass.input_schema.dig(:properties, :par, :properties)).to eq({ ok: {} })
        expect(klass.output_schema[:properties]).to eq({})
      end

      it "reflects such a member on exposes too" do
        member = Class.new do
          def field = :ok
          def validations = {}
        end.new
        klass = build_axn { exposes :par, type: Hash, shape: { members: [member] } }

        expect(klass.output_schema.dig(:properties, :par, :properties)).to eq({ ok: {} })
      end

      it "still emits a description when the member defines one" do
        member = Class.new do
          def field = :ok
          def validations = {}
          def description = "the ok member"
        end.new
        klass = build_axn { expects :par, type: Hash, shape: { members: [member] } }

        expect(klass.input_schema.dig(:properties, :par, :properties, :ok)).to eq({ description: "the ok member" })
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
