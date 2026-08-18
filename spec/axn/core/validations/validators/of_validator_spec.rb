# frozen_string_literal: true

RSpec.describe Axn::Validators::OfValidator do
  # ─── Scalar class ────────────────────────────────────────────────────────────

  describe "of: String" do
    let(:action) do
      build_axn { expects :items, type: Array, of: String, allow_blank: true }
    end

    it "passes when all elements are strings" do
      expect(action.call(items: %w[a b])).to be_ok
    end

    it "fails when any element is not a string" do
      result = action.call(items: ["a", 1])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
    end

    it "passes for empty array (element validation is vacuous; presence is separate)" do
      expect(action.call(items: [])).to be_ok
    end

    it "fails for nil element (nil is not a String)" do
      result = action.call(items: [nil])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
    end
  end

  describe "of: Integer" do
    let(:action) { build_axn { expects :items, type: Array, of: Integer } }

    it "passes for integer elements" do
      expect(action.call(items: [1, 2, 3])).to be_ok
    end

    it "fails for non-integer elements" do
      expect(action.call(items: [1, "two"])).not_to be_ok
    end
  end

  # ─── Symbol types ─────────────────────────────────────────────────────────────

  describe "of: :boolean" do
    let(:action) { build_axn { expects :items, type: Array, of: :boolean } }

    it "passes for true/false elements" do
      expect(action.call(items: [true, false, true])).to be_ok
    end

    it "fails for nil element" do
      expect(action.call(items: [true, nil])).not_to be_ok
    end

    it "fails for truthy non-boolean" do
      expect(action.call(items: [true, 1])).not_to be_ok
    end
  end

  describe "of: :uuid" do
    let(:action) { build_axn { expects :items, type: Array, of: :uuid } }
    let(:valid_uuid) { "550e8400-e29b-41d4-a716-446655440000" }

    it "passes for valid UUID strings" do
      expect(action.call(items: [valid_uuid])).to be_ok
    end

    it "fails for non-UUID strings" do
      expect(action.call(items: ["not-a-uuid"])).not_to be_ok
    end

    it "fails for a blank element even when the field allows blank (allow_blank governs the field, not its elements)" do
      action = build_axn { expects :items, type: Array, of: :uuid, allow_blank: true }
      result = action.call(items: [""])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
    end
  end

  # ─── Union array ──────────────────────────────────────────────────────────────

  describe "of: [String, Numeric]" do
    let(:action) { build_axn { expects :items, type: Array, of: [String, Numeric], allow_blank: true } }

    it "passes when elements are any of the specified types" do
      expect(action.call(items: ["hello", 42, 3.14])).to be_ok
    end

    it "fails when an element matches none" do
      result = action.call(items: ["hello", :not_a_string_or_number])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
      expect(result.exception.message).to include("is not one of")
    end

    it "passes with empty array (element validation is vacuous)" do
      expect(action.call(items: [])).to be_ok
    end
  end

  describe "of: [:boolean, String]" do
    let(:action) { build_axn { expects :items, type: Array, of: [:boolean, String] } }

    it "accepts booleans and strings" do
      expect(action.call(items: [true, "yes", false])).to be_ok
    end

    it "rejects integers" do
      expect(action.call(items: [true, 1])).not_to be_ok
    end
  end

  # ─── Data.define class ───────────────────────────────────────────────────────

  describe "of: <Data.define class>" do
    let(:point_class) { Data.define(:x, :y) }
    let(:action) do
      klass = point_class
      build_axn { expects :items, type: Array, of: klass }
    end

    it "passes when elements are instances of the Data class" do
      expect(action.call(items: [point_class.new(x: 1, y: 2)])).to be_ok
    end

    it "fails for plain hashes — is_a? check is strict" do
      result = action.call(items: [{ x: 1, y: 2 }])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0/)
    end

    it "fails for nil elements" do
      result = action.call(items: [point_class.new(x: 1, y: 2), nil])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
    end
  end

  # ─── Whole-field nil / blank handling ────────────────────────────────────────

  describe "whole-value nil/blank handling" do
    # Each flag governs the *field* (may it be absent?), never its *elements* — a nil
    # element is still rejected regardless of which whole-field flag is set.
    context "with allow_nil" do
      let(:action) { build_axn { expects :items, type: Array, of: String, allow_nil: true } }

      it "skips element validation when value is nil" do
        expect(action.call(items: nil)).to be_ok
      end

      it "still rejects a nil element inside the array" do
        result = action.call(items: ["a", nil])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/element at index 1/)
      end
    end

    context "with allow_blank" do
      let(:action) { build_axn { expects :items, type: Array, of: String, allow_blank: true } }

      it "skips element validation when value is nil" do
        expect(action.call(items: nil)).to be_ok
      end

      it "still rejects a nil element inside the array" do
        result = action.call(items: ["a", nil])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/element at index 1/)
      end
    end

    context "with optional" do
      let(:action) { build_axn { expects :items, type: Array, of: String, optional: true } }

      it "skips element validation when value is nil" do
        expect(action.call(items: nil)).to be_ok
      end

      it "still rejects a nil element inside the array" do
        result = action.call(items: ["a", nil])
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/element at index 1/)
      end
    end
  end

  # ─── Non-Array value (TypeValidator owns that error, OfValidator no-ops) ─────

  describe "when value is not an Array" do
    let(:action) { build_axn { expects :items, type: Array, of: String } }

    it "does not double-report — TypeValidator owns the type error, not OfValidator" do
      result = action.call(items: "not an array")
      expect(result).not_to be_ok
      expect(result.exception.message).not_to match(/element at index/)
    end
  end

  # ─── Declaration-time guards ──────────────────────────────────────────────────

  describe "declaration-time validation" do
    it "raises ArgumentError when of: is used with a type: that is no container at all" do
      expect do
        build_axn { expects :items, type: String, of: String }
      end.to raise_error(ArgumentError, "of: requires type: Array or Hash (got [String])")
    end

    it "raises ArgumentError when type: is a union containing Array" do
      expect do
        build_axn { expects :items, type: [Array, String], of: String }
      end.to raise_error(ArgumentError, "of: requires type: Array or Hash (got [Array, String])")
    end

    it "raises ArgumentError when of: is used without any type:" do
      expect do
        build_axn { expects :items, of: String }
      end.to raise_error(ArgumentError, "of: requires type: Array or Hash (got [])")
    end

    it "raises ArgumentError when of: is a hash with no :klass key" do
      expect do
        build_axn { expects :items, type: Array, of: {} }
      end.to raise_error(ArgumentError, /must supply :klass/)
    end

    it "rejects a nested of: inside the of: bag, which used to constrain nothing" do
      expect do
        build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } }
      end.to raise_error(ArgumentError, /of: does not support of:/)
    end

    it "rejects a nested shape: inside the of: bag" do
      expect do
        build_axn { expects :rows, type: Array, of: { klass: Hash, shape: { members: [] } } }
      end.to raise_error(ArgumentError, /of: does not support shape:/)
    end

    it "rejects a misspelled message: rather than dropping the custom message" do
      expect do
        build_axn { expects :rows, type: Array, of: { klass: String, mesage: "nope" } }
      end.to raise_error(ArgumentError, /of: does not support mesage:/)
    end

    it "names every unsupported key at once" do
      expect do
        build_axn { expects :rows, type: Array, of: { klass: String, wat: 1, huh: 2 } }
      end.to raise_error(ArgumentError, /of: does not support wat:, huh:/)
    end

    it "still accepts the supported keys" do
      expect do
        build_axn { expects :rows, type: Array, of: { klass: String, message: "custom", allow_nil: true } }
      end.not_to raise_error
    end

    it "leaves on: to the context-scope guard, which has the better message" do
      expect do
        build_axn { expects :rows, type: Array, of: { klass: String, on: :create } }
      end.to raise_error(ArgumentError, /validation context/)
    end
  end

  # ─── Hash containers (maps) ───────────────────────────────────────────────────

  describe "Hash containers (maps)" do
    it "accepts keys: and values:" do
      expect { build_axn { expects :counts, type: Hash, of: { keys: Symbol, values: Integer } } }.not_to raise_error
    end

    it "accepts values: alone — an unconstrained key axis is said by omitting it" do
      expect { build_axn { expects :counts, type: Hash, of: { values: Integer } } }.not_to raise_error
    end

    it "accepts keys: alone" do
      expect { build_axn { expects :counts, type: Hash, of: { keys: Symbol } } }.not_to raise_error
    end

    it "accepts a union on either axis" do
      expect { build_axn { expects :counts, type: Hash, of: { keys: [String, Symbol], values: [String, Integer] } } }
        .not_to raise_error
    end

    it "rejects the bare form, which does not say which axis it constrains" do
      expect { build_axn { expects :counts, type: Hash, of: Integer } }
        .to raise_error(ArgumentError, %r{of: requires keys: and/or values: for a Hash})
    end

    it "rejects klass:, pointing at values:" do
      expect { build_axn { expects :counts, type: Hash, of: { klass: Integer } } }
        .to raise_error(ArgumentError, /of: does not support klass:/)
    end

    it "rejects a bag that constrains nothing" do
      expect { build_axn { expects :counts, type: Hash, of: {} } }
        .to raise_error(ArgumentError, %r{of: requires keys: and/or values: for a Hash})
    end

    it "rejects message:, which cannot say which axis failed" do
      expect { build_axn { expects :counts, type: Hash, of: { values: Integer, message: "nope" } } }
        .to raise_error(ArgumentError, /of: does not support message:/)
    end

    it "rejects a nested contract on an axis as not yet supported" do
      expect { build_axn { expects :counts, type: Hash, of: { values: { klass: Integer } } } }
        .to raise_error(ArgumentError, /not supported yet/)
    end

    it "rejects a nested contract inside a union on an axis" do
      expect { build_axn { expects :counts, type: Hash, of: { values: [String, { klass: Integer }] } } }
        .to raise_error(ArgumentError, /not supported yet/)
    end

    it "rejects of: beside shape: on a Hash as not yet supported" do
      expect do
        build_axn do
          expects :counts, type: Hash, of: { values: Integer }, shape: { members: [] }
        end
      end.to raise_error(ArgumentError, /not supported yet/)
    end

    # The same rule in its second spelling. A subfield declared `on:` a map names one of that hash's members
    # exactly as a `shape:` member does, so refusing one spelling and permitting the other would leave the
    # combination half-closed — and the schema it emitted said `{"n": "abc"}` was acceptable where the runtime
    # rejects it, since `additionalProperties` applies only to keys `properties` does not match.
    describe "of: beside a subfield on a Hash" do
      it "rejects a subfield declared directly on a map" do
        expect do
          build_axn do
            expects :counts, type: Hash, of: { values: Integer }
            expects :n, on: :counts, type: String
          end
        end.to raise_error(ArgumentError, /not supported yet/)
      end

      # The other declaration order: the subfield is declared against a node that only BECOMES a map when the
      # later declaration lands, so the guard cannot depend on which arrived first.
      it "rejects the map declared after the subfield it would swallow" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :n, on: "payload.counts", type: String
            expects :counts, on: :payload, type: Hash, of: { values: Integer }
          end
        end.to raise_error(ArgumentError, /not supported yet/)
      end

      it "rejects a subfield any depth below the map, through a dotted on:" do
        expect do
          build_axn do
            expects :counts, type: Hash, of: { values: Hash }
            expects :n, on: "counts.inner", type: String
          end
        end.to raise_error(ArgumentError, /not supported yet/)
      end

      it "names both declarations, so the author knows which two to reconcile" do
        expect do
          build_axn do
            expects :counts, type: Hash, of: { values: Integer }
            expects :n, on: :counts, type: String
          end
        end.to raise_error(ArgumentError, /subfield :n \(on :counts\) names the key :n of :counts/)
      end

      # The path that must NOT regress: an ordinary Hash parent has no `of:` and takes subfields as it always
      # has — the refusal is about the two ways of naming a map's members, not about Hash parents.
      it "leaves an ordinary Hash parent's subfields alone" do
        klass = nil
        expect do
          klass = build_axn do
            expects :counts, type: Hash
            expects :n, on: :counts, type: String
          end
        end.not_to raise_error
        expect(klass.input_schema.dig(:properties, :counts, :properties, :n)).to include(type: "string")
      end

      # An ARRAY `of:` names element positions rather than members, so a subfield beside one is a different
      # question and stays legal.
      it "leaves an Array of: alone" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :ids, on: :payload, type: Array, of: Integer
          end
        end.not_to raise_error
      end
    end

    it "rejects values: on an Array, pointing at klass:" do
      expect { build_axn { expects :ids, type: Array, of: { values: Integer } } }
        .to raise_error(ArgumentError, /of: does not support values:/)
    end

    it "rejects a union type:, from which no container can be derived" do
      expect { build_axn { expects :counts, type: [Array, Hash], of: { values: Integer } } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [Array, Hash])")
    end

    it "rejects of: with no type: at all" do
      expect { build_axn { expects :counts, of: { values: Integer } } }
        .to raise_error(ArgumentError, "of: requires type: Array or Hash (got [])")
    end

    it "holds a shape member's bag to the same rules, since both pass through one seam" do
      expect do
        build_axn do
          expects :order, type: Hash do
            field :counts, type: Hash, of: { klass: Integer }
          end
        end
      end.to raise_error(ArgumentError, /of: does not support klass:/)
    end
  end

  # ─── The derived container ────────────────────────────────────────────────────

  describe "the container the canonical bag carries" do
    def of_bag(klass, field) = klass.internal_field_configs.find { |config| config.field == field }.validations[:of]

    def member_of_bag(klass, member)
      klass.internal_field_configs.first.validations[:shape][:members].find { |m| m.field == member }.validations[:of]
    end

    it "records Array for an Array field, beside the element class" do
      bag = of_bag(build_axn { expects :ids, type: Array, of: Integer }, :ids)

      expect(bag[:container]).to eq(Array)
      expect(bag[:klass]).to eq(Integer)
    end

    it "records Hash for a map field, beside the axes" do
      bag = of_bag(build_axn { expects :counts, type: Hash, of: { keys: Symbol, values: Integer } }, :counts)

      expect(bag[:container]).to eq(Hash)
      expect(bag[:keys]).to eq(Symbol)
      expect(bag[:values]).to eq(Integer)
      expect(bag).not_to have_key(:klass)
    end

    # A shape member's bag reaches the canonicalization seam TWICE — once as the member is built like a field
    # (`_parse_field_configs`), and again as the declaration walk snapshots it
    # (`_symbol_keyed_member_validations`), which is handed the very bag the first pass produced. The derived
    # `container:` is a key no caller may write, so a second pass that did not account for it would report axn's
    # own key as unsupported and fail a declaration that is perfectly well-formed.
    it "canonicalizes a shape member's bag idempotently, though the seam runs over it twice" do
      klass = nil
      expect do
        klass = build_axn do
          expects :order, type: Hash do
            field :ids, type: Array, of: Integer
            field :counts, type: Hash, of: { values: Integer }
          end
        end
      end.not_to raise_error

      expect(member_of_bag(klass, :ids)[:container]).to eq(Array)
      expect(member_of_bag(klass, :counts)[:container]).to eq(Hash)
    end

    it "refuses a container: naming something other than the declared type:" do
      expect { build_axn { expects :ids, type: Array, of: { klass: Integer, container: Hash } } }
        .to raise_error(ArgumentError, /of: does not support container:/)
    end

    # The other half of the same rule: the container is DERIVED, so one written out by hand is dropped and
    # derived again rather than believed. Redundant rather than refused — the declaration means exactly what
    # it would without the key — because nothing distinguishes it from the key axn itself derived.
    it "derives the container over a hand-written one that agrees with the declared type:" do
      bag = of_bag(build_axn { expects :ids, type: Array, of: { klass: Integer, container: Array } }, :ids)

      expect(bag[:container]).to eq(Array)
      expect(bag[:klass]).to eq(Integer)
    end
  end

  # ─── Works on exposes too ─────────────────────────────────────────────────────

  describe "on exposes" do
    let(:action) do
      build_axn do
        expects :raw_items, type: Array
        exposes :items, type: Array, of: Integer

        def call
          expose :items, raw_items
        end
      end
    end

    it "validates exposed array elements" do
      result = action.call(raw_items: [1, 2, "three"])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 2/)
    end

    it "passes when exposed array elements match" do
      expect(action.call(raw_items: [1, 2, 3])).to be_ok
    end
  end

  # ─── Works on subfields (on:) too ─────────────────────────────────────────────

  describe "on expects with on: (subfields)" do
    let(:action) do
      build_axn do
        expects :payload, type: Hash
        expects :tags, on: :payload, type: Array, of: String
      end
    end

    it "passes when subfield array elements match" do
      expect(action.call(payload: { tags: %w[a b] })).to be_ok
    end

    it "fails when a subfield array element does not match" do
      result = action.call(payload: { tags: ["a", 2] })
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 1/)
    end
  end

  # ─── Error message quality ────────────────────────────────────────────────────

  describe "error messages" do
    it "names the single expected type" do
      action = build_axn { expects :items, type: Array, of: String }
      result = action.call(items: [42])
      expect(result.exception.message).to include("is not a String")
    end

    it "names all expected types for a union" do
      action = build_axn { expects :items, type: Array, of: [String, Integer] }
      result = action.call(items: [:sym])
      expect(result.exception.message).to include("is not one of")
    end

    it "includes the index of each failing element" do
      action = build_axn { expects :items, type: Array, of: String, allow_blank: true }
      result = action.call(items: [1, 2, 3])
      expect(result.exception.message).to match(/element at index 0/)
    end

    it "honors a custom message: while still reporting the element index" do
      action = build_axn { expects :items, type: Array, of: { klass: String, message: "must be a string" } }
      result = action.call(items: [42])
      expect(result.exception.message).to include("must be a string")
      expect(result.exception.message).to match(/element at index 0/)
    end
  end

  # ─── Hash containers (maps) ───────────────────────────────────────────────────

  describe "Hash containers (maps) at runtime" do
    subject(:action) do
      build_axn do
        expects :counts, type: Hash, of: { keys: Symbol, values: Integer }
        def call = nil
      end
    end

    it "accepts a map matching both axes" do
      expect(action.call(counts: { acme: 1, globex: 2 })).to be_ok
    end

    it "accepts an empty map — emptiness is allow_empty's business, not of:'s" do
      emptiable = build_axn do
        expects :counts, type: Hash, of: { keys: Symbol, values: Integer }, allow_empty: true
        def call = nil
      end
      expect(emptiable.call(counts: {})).to be_ok
    end

    it "reports the offending key by the position that located it" do
      result = action.call(counts: { "acme" => 1 })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("key at index 0 is not a Symbol")
    end

    it "reports the offending value by the position that located it" do
      result = action.call(counts: { acme: 1, globex: "2" })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 1 is not a Integer")
    end

    it "reports both axes independently when both are wrong" do
      result = action.call(counts: { "acme" => "1" })
      message = result.exception.message
      expect(message).to include("key at index 0 is not a Symbol")
      expect(message).to include("value at index 0 is not a Integer")
    end

    it "names a union on the failing axis" do
      unioned = build_axn do
        expects :counts, type: Hash, of: { values: [String, Integer] }
        def call = nil
      end
      expect(unioned.call(counts: { a: 1.5 }).exception.message).to include("value at index 0 is not one of String, Integer")
    end

    it "leaves the non-Hash error to TypeValidator" do
      result = action.call(counts: "not a hash")
      expect(result).not_to be_ok
      expect(result.exception.message).not_to match(/value at index/)
    end

    it "reports an entry without asking its key to render itself" do
      hostile = Class.new do
        def inspect = raise("nope")
        def to_s = raise("nope")
      end
      keyed = build_axn do
        expects :counts, type: Hash, of: { values: Integer }
        def call = nil
      end
      result = keyed.call(counts: { hostile.new => "x" })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 0 is not a Integer")
    end

    it "validates the entries a Hash subclass holds rather than the ones its own each yields" do
      concealing = Class.new(Hash) do
        def each; end
      end
      counts = concealing.new
      counts["acme"] = 1

      result = action.call(counts:)
      expect(result).not_to be_ok
      expect(result.exception.message).to include("key at index 0 is not a Symbol")
    end

    it "does not leak a sensitive map's keys or values into the message" do
      secrets = build_axn do
        expects :counts, type: Hash, sensitive: true, of: { keys: Symbol, values: Integer }
        def call = nil
      end

      message = secrets.call(counts: { "sk-live-SECRET" => "tok-VALUE" }).exception.message
      expect(message).to include("key at index 0 is not a Symbol")
      expect(message).to include("value at index 0 is not a Integer")
      expect(message).not_to include("sk-live-SECRET")
      expect(message).not_to include("tok-VALUE")
    end

    it "locates by position rather than by key for a non-sensitive map too" do
      message = action.call(counts: { "acme" => "1" }).exception.message
      expect(message).to include("key at index 0")
      expect(message).not_to include("acme")
    end

    it "counts the position per entry so sibling failures are told apart" do
      message = action.call(counts: { a: "1", b: 2, c: "3" }).exception.message
      expect(message).to include("value at index 0 is not a Integer")
      expect(message).to include("value at index 2 is not a Integer")
      expect(message).not_to include("value at index 1")
    end

    it "constrains only the declared axis" do
      values_only = build_axn do
        expects :counts, type: Hash, of: { values: Integer }
        def call = nil
      end
      expect(values_only.call(counts: { "anything" => 1 })).to be_ok
    end
  end
end
