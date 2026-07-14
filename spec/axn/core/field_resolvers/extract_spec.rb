# frozen_string_literal: true

RSpec.describe Axn::Core::FieldResolvers::Extract do
  def extract(field, data, permit_method_call: false)
    Axn::Core::FieldResolvers.resolve(type: :extract, field:, provided_data: data, permit_method_call:)
  end

  describe "Hash sources" do
    it "reads a key whose name collides with an Enumerable/Hash method" do
      expect(extract(:zip, { zip: "12345" })).to eq("12345")
      expect(extract(:count, { count: 5 })).to eq(5)
      expect(extract(:first, { first: "a" })).to eq("a")
      expect(extract(:min, { min: 1 })).to eq(1)
    end

    it "reads ordinary keys (string or symbol, indifferently)" do
      expect(extract(:name, { name: "x" })).to eq("x")
      expect(extract(:name, { "name" => "x" })).to eq("x")
    end

    it "digs dotted paths" do
      expect(extract("a.b", { a: { b: 1 } })).to eq(1)
    end

    it "digs dotted paths through symbol-keyed nested hashes indifferently" do
      expect(extract("a.b.c", { a: { b: { c: 1 } } })).to eq(1)
    end

    it "returns nil for a missing key" do
      expect(extract(:missing, { name: "x" })).to be_nil
    end

    it "reads indifferently from a HashWithIndifferentAccess source" do
      hwia = { a: { b: 1 } }.with_indifferent_access
      expect(extract("a.b", hwia)).to eq(1)
      expect(extract(:missing, hwia)).to be_nil
    end

    it "reads a key whose value is present but nil (not treated as absent differently than dig)" do
      expect(extract(:name, { name: nil })).to be_nil
    end

    it "does not mutate or convert the source hash" do
      source = { a: { b: 1 } }
      extract("a.b", source)
      expect(source).to eq({ a: { b: 1 } })
      expect(source[:a]).not_to be_a(ActiveSupport::HashWithIndifferentAccess)
    end
  end

  describe "dotted paths with a Hash-key final segment (safe, no method dispatch)" do
    it "reads a Hash key whose name collides with an Array method (per-segment dispatch)" do
      # The final `count` segment lands on a Hash, so it reads the key (99), not Array#count.
      expect(extract("data.count", { data: { count: 99 } })).to eq(99)
    end

    it "returns nil for a missing intermediate rather than raising" do
      expect(extract("a.b.c", { a: {} })).to be_nil
      expect(extract("a.b.c", { a: { b: nil } })).to be_nil
    end

    it "raises when a non-terminal segment lands on a value that can neither dig nor answer the reader" do
      expect { extract("a.b", { a: 5 }) }.to raise_error(/Unclear how to extract/)
    end
  end

  describe "nil source" do
    # A nil source means "absent" — extracting any field yields nil rather than raising, so a
    # subfield hanging off a nil/omitted parent validates against nil (optional passes, required
    # fails cleanly) instead of blowing up mid-extraction (PRO-2857).
    it "returns nil for any field" do
      expect(extract(:anything, nil)).to be_nil
      expect(extract("a.b", nil)).to be_nil
    end
  end

  describe "Struct sources (diggable non-Hash)" do
    # A Struct responds to #dig, so it reads by member name — but `Struct#[]` raises NameError for
    # an unknown member while `#dig` returns nil, so a missing member must read as absent, not crash.
    let(:point) { Struct.new(:name).new("here") }

    it "reads a present member" do
      expect(extract(:name, point)).to eq("here")
    end

    it "returns nil for a missing member rather than raising" do
      expect(extract(:missing, point)).to be_nil
      expect(extract("nested.missing", { nested: point })).to be_nil
    end
  end

  describe "Data sources (member read is safe — no method dispatch)" do
    # A Data instance isn't diggable, but its declared members are DATA, not behavior — read them
    # through `#to_h` so no method is ever invoked. This is the safe path: no `method_call:` needed.
    let(:klass) { Data.define(:zip, :city) }

    it "reads a declared member without permit_method_call" do
      obj = klass.new(zip: "v", city: "SF")
      expect(extract(:zip, obj)).to eq("v")
      expect(extract(:city, obj)).to eq("SF")
    end

    it "reads a declared member nested under a Hash without permit_method_call" do
      obj = klass.new(zip: "v", city: "SF")
      expect(extract("addr.zip", { addr: obj })).to eq("v")
    end

    it "reads a member whose declared value is nil" do
      obj = klass.new(zip: nil, city: "SF")
      expect(extract(:zip, obj)).to be_nil
    end

    it "reads the declared member even when the Data subclass overrides #to_h" do
      # A member read must not route through a custom serializer: it reads the built-in member hash,
      # so a `to_h` override (returning a scalar, or a re-keyed/partial hash) can't break or misresolve
      # a declared member.
      overriding = Data.define(:name) do
        def to_h = "not a hash"
      end
      expect(extract(:name, overriding.new(name: "Ada"))).to eq("Ada")
    end
  end

  describe "method dispatch (sharp path) gated by permit_method_call" do
    # Any segment that can only be reached by INVOKING it as a method (Array methods, PORO readers,
    # a Data *behavioral* method that is not a declared member) is the sharp path. It resolves only
    # when the caller permits method dispatch; otherwise it raises a distinct, non-swallowed error.

    describe "without permit_method_call" do
      it "raises MethodCallNotPermittedError for an Array method segment (items.count)" do
        expect { extract("items.count", { items: [10, 20, 30] }) }
          .to raise_error(Axn::ContractViolation::MethodCallNotPermittedError, /method_call: true/)
      end

      it "raises for a top-level Array method segment (count on an Array)" do
        expect { extract(:count, [1, 2, 3]) }.to raise_error(Axn::ContractViolation::MethodCallNotPermittedError)
      end

      it "raises for a PORO reader segment (event.data-shaped attr_reader)" do
        # A plain object exposing `data` via a reader (not dig/[]): the classic os-app event shape.
        obj = Class.new do
          attr_reader :data

          def initialize(d) = (@data = d)
        end.new({ x: 1 })

        expect { extract(:data, obj) }.to raise_error(Axn::ContractViolation::MethodCallNotPermittedError)
      end

      it "raises for a Data behavioral method (not a declared member)" do
        klass = Data.define(:amount) { def doubled = amount * 2 }
        obj = klass.new(amount: 5)
        expect(extract(:amount, obj)).to eq(5) # member read stays safe
        expect { extract(:doubled, obj) }.to raise_error(Axn::ContractViolation::MethodCallNotPermittedError)
      end

      it "names the field, the parent's runtime class, and the fix in the message" do
        expect { extract("items.count", { items: [1, 2] }) }
          .to raise_error(Axn::ContractViolation::MethodCallNotPermittedError) { |e|
            expect(e.message).to include("items.count")
            expect(e.message).to include("Array")
            expect(e.message).to include("method_call: true")
          }
      end
    end

    describe "with permit_method_call: true" do
      it "method-reads an Array segment nested under a Hash (items.count)" do
        expect(extract("items.count", { items: [10, 20, 30] }, permit_method_call: true)).to eq(3)
      end

      it "chains reader methods across nested Arrays" do
        expect(extract("rows.first", { rows: [%w[a b], %w[c d]] }, permit_method_call: true)).to eq(%w[a b])
      end

      it "reads a top-level Array method" do
        expect(extract(:count, [1, 2, 3], permit_method_call: true)).to eq(3)
        expect(extract(:first, %w[a b], permit_method_call: true)).to eq("a")
      end

      it "reads a PORO reader (event.data)" do
        obj = Class.new do
          attr_reader :data

          def initialize(d) = (@data = d)
        end.new({ x: 1 })

        expect(extract(:data, obj, permit_method_call: true)).to eq({ x: 1 })
      end

      it "invokes a Data behavioral method" do
        klass = Data.define(:amount) { def doubled = amount * 2 }
        expect(extract(:doubled, klass.new(amount: 5), permit_method_call: true)).to eq(10)
      end

      # The PR #162 arity edges must survive verbatim once dispatch is permitted.
      it "raises the typed UnextractableError for a reader needing arguments" do
        expect { extract("items.fetch", { items: [1, 2] }, permit_method_call: true) }
          .to raise_error(Axn::ContractViolation::UnextractableError)
        expect { extract(:fetch, [1, 2], permit_method_call: true) }
          .to raise_error(Axn::ContractViolation::UnextractableError)
      end

      it "does not swallow an ArgumentError the reader itself raises" do
        obj = Object.new
        def obj.boom = raise(ArgumentError, "reader is broken")
        expect { extract(:boom, obj, permit_method_call: true) }.to raise_error(ArgumentError, "reader is broken")
      end

      it "surfaces an arity-worded ArgumentError raised inside a bare-callable reader" do
        obj = Object.new
        def obj.total = broken_helper
        def obj.broken_helper(required) = required
        expect { extract(:total, obj, permit_method_call: true) }.to raise_error(ArgumentError, /wrong number of arguments/)
      end

      it "treats a required-argument reader as unextractable (positional or keyword)" do
        obj = Object.new
        def obj.needs_positional(arg) = arg
        def obj.lookup(id:) = id
        expect { extract("nested.needs_positional", { nested: obj }, permit_method_call: true) }
          .to raise_error(Axn::ContractViolation::UnextractableError)
        expect { extract("nested.lookup", { nested: obj }, permit_method_call: true) }
          .to raise_error(Axn::ContractViolation::UnextractableError)
      end
    end
  end

  describe "object sources (non-diggable, no matching reader)" do
    it "raises UnextractableError when the object does not respond to the field" do
      expect { extract(:nope, Object.new) }.to raise_error(Axn::ContractViolation::UnextractableError, /Unclear how to extract/)
    end
  end

  describe ".extract_or_nil" do
    # The tolerant read for the subfield contract machinery: an UnextractableError reads as ABSENT,
    # but a forgotten `method_call:` must NOT — it propagates loudly (the "loud, never silent"
    # guarantee), else a gated `event.data` would validate against nil and silently change semantics.
    it "swallows UnextractableError to nil" do
      expect(Axn::Core::FieldResolvers.extract_or_nil(field: :nope, provided_data: Object.new)).to be_nil
    end

    it "does NOT swallow MethodCallNotPermittedError" do
      expect { Axn::Core::FieldResolvers.extract_or_nil(field: "items.count", provided_data: { items: [1, 2] }) }
        .to raise_error(Axn::ContractViolation::MethodCallNotPermittedError)
    end

    it "forwards permit_method_call so a permitted method dispatch still resolves" do
      expect(Axn::Core::FieldResolvers.extract_or_nil(field: "items.count", provided_data: { items: [1, 2] },
                                                      permit_method_call: true)).to eq(2)
    end
  end
end
