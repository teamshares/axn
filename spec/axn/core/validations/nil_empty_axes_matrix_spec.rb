# frozen_string_literal: true

# Each container type paired with an empty and a non-empty instance of itself.
containers = {
  Array => { empty: [], filled: [1] },
  Hash => { empty: {}, filled: { a: 1 } },
  String => { empty: "", filled: "x" },
  Set => { empty: Set.new, filled: Set["x"] },
}.freeze

RSpec.describe "nil and empty axes" do
  def build(**opts)
    Class.new do
      include Axn
      expects :v, **opts
      def call = nil
    end
  end

  describe "allow_empty: true — required, non-nil, may be empty" do
    containers.each do |klass, values|
      context "with type: #{klass}" do
        subject(:action) { build(type: klass, allow_empty: true) }

        it "rejects nil" do
          result = action.call(v: nil)
          expect(result).not_to be_ok
          expect(result.exception.message).to include("is not a #{klass}")
        end

        it "accepts an empty #{klass}" do
          expect(action.call(v: values[:empty])).to be_ok
        end

        it "accepts a non-empty #{klass}" do
          expect(action.call(v: values[:filled])).to be_ok
        end

        it "rejects an omitted key" do
          expect(action.call).not_to be_ok
        end
      end
    end

    it "keeps of: element checks working alongside it" do
      action = build(type: Array, of: Integer, allow_empty: true)
      expect(action.call(v: [])).to be_ok
      expect(action.call(v: ["1"])).not_to be_ok
    end

    it "does not tolerate a wrong-typed blank" do
      expect(build(type: Hash, allow_empty: true).call(v: "")).not_to be_ok
    end

    it "permits allow_empty: true alongside optional: as a redundant restatement of the tolerance" do
      action = build(type: Array, optional: true, allow_empty: true)
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: [])).to be_ok
      expect(action.call(v: [1])).to be_ok
    end
  end

  describe "the declaration guard" do
    it "rejects a type whose instances cannot be empty" do
      expect { build(type: Integer, allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*Integer.*cannot be empty/)
    end

    it "rejects :boolean" do
      expect { build(type: :boolean, allow_empty: true) }.to raise_error(ArgumentError, /allow_empty:/)
    end

    it "rejects a declaration with no type at all" do
      expect { build(allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*requires a `type:`/)
    end

    it "accepts :params" do
      expect { build(type: :params, allow_empty: true) }.not_to raise_error
    end

    # TypeValidator matches with `is_a?`, so a bare MODULE is a supported `type:` — and one supplying
    # `empty?` describes values with a real empty state, which is the whole question the guard asks.
    describe "a module type" do
      let(:emptiable) do
        Module.new do
          def self.name = "EmptyCollection"
          def empty? = to_a.empty?
        end
      end

      let(:bag) do
        mod = emptiable
        Class.new do
          include mod
          def initialize(items = []) = @items = items
          def to_a = @items
        end
      end

      it "accepts a module supplying empty?, in both polarities" do
        expect { build(type: emptiable, allow_empty: true) }.not_to raise_error
        expect { build(type: emptiable, optional: true, allow_empty: false) }.not_to raise_error
      end

      it "still rejects a module with no empty? of its own" do
        expect { build(type: Enumerable, allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty:.*Enumerable.*cannot be empty/)
      end

      it "permits an empty value under allow_empty: true, and still rejects nil" do
        action = build(type: emptiable, allow_empty: true)
        expect(action.call(v: bag.new)).to be_ok
        expect(action.call(v: bag.new([1]))).to be_ok
        expect(action.call(v: nil)).not_to be_ok
        expect(action.call(v: "x")).not_to be_ok
      end

      it "rejects an empty value under allow_empty: false, and still accepts nil" do
        action = build(type: emptiable, optional: true, allow_empty: false)
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: bag.new([1]))).to be_ok
        expect(action.call(v: bag.new).exception.message).to include("can't be empty")
      end

      # The check asks whether the value HAS a public `empty?`, never whether it says it does: a caller's
      # own `respond_to?` is the caller's to define, and a declared contract may not be disabled by it.
      describe "a value whose reflection lies" do
        let(:proxy) do
          mod = emptiable
          Class.new do
            include mod
            def initialize(items = []) = @items = items
            def to_a = @items
            # rubocop:disable Style/OptionalBooleanParameter -- mirrors Object#respond_to?'s own signature
            def respond_to?(_name, _include_private = false) = false
            def respond_to_missing?(_name, _include_private = false) = false
            # rubocop:enable Style/OptionalBooleanParameter
          end
        end

        it "rejects its empty value all the same" do
          action = build(type: emptiable, optional: true, allow_empty: false)

          expect(action.call(v: proxy.new).exception.message).to include("can't be empty")
          expect(action.call(v: proxy.new([1]))).to be_ok
          expect(action.call(v: bag.new).exception.message).to include("can't be empty")
          expect(action.call(v: bag.new([1]))).to be_ok
        end

        it "leaves allow_empty: true alone, which installs no check at all" do
          action = build(type: emptiable, allow_empty: true)

          expect(action.call(v: proxy.new)).to be_ok
          expect(action.call(v: bag.new)).to be_ok
        end
      end

      # A value can satisfy the declared type and still not answer `empty?` — the declaration guard proves the
      # TYPE has an empty state, not that every instance keeps the method. The contract is then unverifiable,
      # and silence is the one outcome that is certainly wrong.
      describe "a value of the declared type that cannot answer" do
        let(:base) do
          Class.new do
            def self.name = "Base0"
            def initialize(items = []) = @items = items
            def to_a = @items
            def empty? = @items.empty?
          end
        end

        let(:stripped) do
          Class.new(base) do
            def self.name = "Stripped"
            undef_method :empty?
          end
        end

        it "fails rather than passing it silently" do
          action = build(type: base, optional: true, allow_empty: false)

          expect(stripped.new.is_a?(base)).to be(true) # the type check accepts it
          result = action.call(v: stripped.new)
          expect(result).not_to be_ok
          expect(result.exception.message).to include("cannot be checked for emptiness")
        end

        # A test double stands in for a value of the declared type rather than being one, and type validation
        # already waives it on those terms — so a spec that supplies one must not fail here instead.
        it "waives a test double, as the type check does" do
          allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("test"))
          action = build(type: Array, optional: true, allow_empty: false)

          expect(action.call(v: instance_double(Array))).to be_ok
          expect(action.call(v: []).exception.message).to include("can't be empty")
        end

        it "leaves the declared type's own values judged as before" do
          action = build(type: base, optional: true, allow_empty: false)

          expect(action.call(v: base.new).exception.message).to include("can't be empty")
          expect(action.call(v: base.new([1]))).to be_ok
          expect(action.call(v: nil)).to be_ok
        end
      end

      # A value that cannot answer `empty?` is the wrong type, and the type check owns that error — the
      # emptiness check must stand aside rather than raise a NoMethodError over it.
      it "leaves a value with no empty? of its own to the type check" do
        action = build(type: emptiable, optional: true, allow_empty: false)
        result = action.call(v: 5)

        expect(result.exception.message).to include("is not a")
        expect(result.exception.message).not_to include("undefined method")
      end

      # THE one-error control: a wrong-typed value is one defect, reported once, by the check that owns it.
      it "reports a wrong-typed value exactly once" do
        action = build(type: Array, optional: true, allow_empty: false)
        message = action.call(v: 5).exception.message

        expect(message).to eq("V is not a Array")
      end

      # A value can acquire the declared module — and with it `empty?` — on its singleton alone, where the
      # value's CLASS never gains the method. The check has to see that too.
      it "sees an empty? the value carries on its singleton" do
        action = build(type: emptiable, optional: true, allow_empty: false)
        empty_one = Object.new.extend(emptiable)
        empty_one.define_singleton_method(:to_a) { [] }
        filled_one = Object.new.extend(emptiable)
        filled_one.define_singleton_method(:to_a) { [1] }

        expect(empty_one.class.public_method_defined?(:empty?)).to be(false) # only the singleton has it
        expect(action.call(v: empty_one).exception.message).to include("can't be empty")
        expect(action.call(v: filled_one)).to be_ok
      end

      it "asks a frozen value without raising" do
        action = build(type: emptiable, optional: true, allow_empty: false)

        expect(action.call(v: bag.new.freeze).exception.message).to include("can't be empty")
        expect(action.call(v: bag.new([1]).freeze)).to be_ok
      end

      it "holds every member of a union to the same question" do
        expect { build(type: [emptiable, Array], allow_empty: true) }.not_to raise_error
        expect { build(type: [emptiable, Integer], allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty:.*Integer.*cannot be empty/)
      end
    end

    # The guard reads the declared type's METHOD TABLE, never the type's answers about itself: a class or
    # module may define `is_a?` or `public_method_defined?`, and one that lies would turn a declaration error
    # into a runtime failure (or refuse a type that is perfectly empty-capable).
    describe "a declared type whose reflection lies" do
      it "accepts a type that has empty? but denies defining it" do
        liar = Module.new do
          def self.public_method_defined?(*) = false
          def empty? = true
        end

        expect { build(type: liar, allow_empty: true) }.not_to raise_error
      end

      it "rejects a type that claims empty? without defining it" do
        boaster = Module.new do
          def self.public_method_defined?(*) = true
        end

        expect { build(type: boaster, allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty:.*cannot be empty/)
      end

      it "rejects a declared klass that claims to be a Module without being one" do
        impostor = Object.new
        impostor.define_singleton_method(:is_a?) { |_klass| true }
        impostor.define_singleton_method(:public_method_defined?) { |*| true }

        # Declared inside the type bag, since the bare-`type:` sugar asks a value `is_a?(Hash)` before this
        # guard is ever reached.
        expect { build(type: { klass: impostor }, allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty:.*cannot be empty/)
      end
    end

    # Naming an unsupported TYPE must not run the type's code either — a class or module can define `inspect`,
    # and one that raises replaces an actionable declaration error with the caller's exception.
    describe "an unsupported type that cannot be inspected" do
      it "reports the declaration error rather than the type's own exception" do
        hostile = Module.new do
          def self.inspect = raise("inspect ran")
        end

        expect { build(type: hostile, allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty: is not supported/)
      end

      it "survives an inspect that raises outside StandardError" do
        hostile = Module.new do
          def self.inspect = raise(SystemStackError, "stack level too deep")
        end

        expect { build(type: hostile, allow_empty: true) }
          .to raise_error(ArgumentError, /allow_empty: is not supported/)
      end

      it "still names each offending type recognizably" do
        expect { build(type: Integer, allow_empty: true) }
          .to raise_error(ArgumentError, /is not supported for Integer on .*Drop allow_empty:/m)
        expect { build(type: :boolean, allow_empty: true) }
          .to raise_error(ArgumentError, /is not supported for :boolean/)
        expect { build(type: :uuid, allow_empty: true) }
          .to raise_error(ArgumentError, /is not supported for :uuid/)
        expect { build(type: [Array, Integer, :boolean], allow_empty: true) }
          .to raise_error(ArgumentError, %r{is not supported for Integer/:boolean})
      end
    end

    # Reporting an invalid value must not run the value's code: an `inspect` that raises replaces the
    # declaration error with the caller's exception, and one outside StandardError escapes every rescue.
    describe "an invalid allow_empty: value that cannot be inspected" do
      it "reports the declaration error rather than the value's own exception" do
        hostile = Object.new
        hostile.define_singleton_method(:inspect) { raise "inspect ran" }

        expect { build(type: Array, allow_empty: hostile) }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end

      it "survives an inspect that raises outside StandardError" do
        hostile = Object.new
        hostile.define_singleton_method(:inspect) { raise SystemStackError, "stack level too deep" }

        expect { build(type: Array, allow_empty: hostile) }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end

      it "still describes the offending value by class" do
        expect { build(type: Array, allow_empty: "false") }
          .to raise_error(ArgumentError, /got a value of class String/)
      end
    end

    # The option has exactly three states, and Ruby truthiness would read anything else as one of the two
    # poles — `allow_empty: "false"` as "empty is acceptable", the precise opposite of what it says.
    describe "the value grammar" do
      it "rejects a String, which truthiness would read as the opposite of what it spells" do
        expect { build(type: Array, allow_empty: "false") }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil.*got a value of class String/m)
      end

      it "rejects an Integer" do
        expect { build(type: Array, allow_empty: 1) }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil.*got a value of class Integer/m)
      end

      it "rejects a Symbol" do
        expect { build(type: Array, allow_empty: :nope) }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil.*got a value of class Symbol/m)
      end

      it "reports a bad value as a bad value, not as a problem with the type it was declared on" do
        expect { build(type: Integer, allow_empty: "false") }
          .to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end

      it "keeps all three legal states declarable" do
        expect { build(type: Array, allow_empty: true) }.not_to raise_error
        expect { build(type: Array, allow_empty: false) }.not_to raise_error
        expect { build(type: Array, allow_empty: nil) }.not_to raise_error
      end

      it "fires on a subfield too" do
        expect do
          Class.new do
            include Axn
            expects :payload, type: Hash
            expects :list, on: :payload, type: Array, allow_empty: "false"
            def call = nil
          end
        end.to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end

      it "fires on a shape member too" do
        expect do
          Class.new do
            include Axn
            expects :snapshot, type: Hash do
              field :history, type: Hash, allow_empty: "false"
            end
            def call = nil
          end
        end.to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end

      it "fires on exposes too" do
        expect do
          Class.new do
            include Axn
            exposes :out, type: Array, allow_empty: "false"
            def call = expose(:out, [])
          end
        end.to raise_error(ArgumentError, /allow_empty: must be true, false, or nil/)
      end
    end
  end

  describe "parity across declaration sites" do
    it "works on exposes" do
      klass = Class.new do
        include Axn
        exposes :out, type: Array, allow_empty: true
        def call = expose(:out, [])
      end
      expect(klass.call).to be_ok
    end

    it "works on a subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :list, on: :payload, type: Array, allow_empty: true
        def call = nil
      end
      expect(klass.call(payload: { list: [] })).to be_ok
      expect(klass.call(payload: { list: nil })).not_to be_ok
    end

    it "works on a shape member" do
      klass = Class.new do
        include Axn
        expects :snapshot, type: Hash do
          field :history, type: Hash, allow_empty: true
          field :months, type: Array, of: Integer, allow_empty: true
        end
        def call = nil
      end

      expect(klass.call(snapshot: { history: {}, months: [] })).to be_ok
      expect(klass.call(snapshot: { history: nil, months: [] })).not_to be_ok
      expect(klass.call(snapshot: { history: {}, months: nil })).not_to be_ok
    end

    it "names the offending member when a nested collection is nil" do
      klass = Class.new do
        include Axn
        expects :snapshot, type: Hash do
          field :history, type: Hash, allow_empty: true
        end
        def call = nil
      end

      result = klass.call(snapshot: { history: nil })
      expect(result.exception.message).to include("history")
    end

    it "guards a non-empty-able member type at declaration" do
      expect do
        Class.new do
          include Axn
          expects :snapshot, type: Hash do
            field :count, type: Integer, allow_empty: true
          end
          def call = nil
        end
      end.to raise_error(ArgumentError, /allow_empty:/)
    end
  end

  describe "allow_empty: false — may be nil, must be non-empty" do
    containers.each do |klass, values|
      context "with type: #{klass}" do
        subject(:action) { build(type: klass, optional: true, allow_empty: false) }

        it "accepts nil" do
          expect(action.call(v: nil)).to be_ok
        end

        it "accepts an omitted key" do
          expect(action.call).to be_ok
        end

        it "rejects an empty #{klass}" do
          result = action.call(v: values[:empty])
          expect(result).not_to be_ok
          expect(result.exception.message).to include("can't be empty")
        end

        it "accepts a non-empty #{klass}" do
          expect(action.call(v: values[:filled])).to be_ok
        end
      end
    end

    it "treats a whitespace-only String as non-empty" do
      action = build(type: String, optional: true, allow_empty: false)
      expect(action.call(v: " ")).to be_ok
    end

    # The axis is `empty?`, so it fires on any value that answers the question — including one whose size
    # cannot be measured. `ActionController::Parameters` is the case in the wild (covered in spec_rails,
    # where Rails is loaded); this container stands in for the whole class of them.
    it "rejects an empty value that answers empty? but reports no size" do
      bag = Class.new do
        def initialize(items = []) = @items = items
        def empty? = @items.empty?
        def to_s = "bag"
      end

      action = build(type: bag, optional: true, allow_empty: false)
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: bag.new([1]))).to be_ok

      result = action.call(v: bag.new)
      expect(result).not_to be_ok
      expect(result.exception.message).to include("can't be empty")
    end

    it "is a no-op restatement of the default when no nil-tolerance is declared" do
      action = build(type: Array, allow_empty: false)
      expect(action.call(v: nil)).not_to be_ok
      expect(action.call(v: [])).not_to be_ok
      expect(action.call(v: [1])).to be_ok
    end

    it "defers to an author-declared length minimum" do
      action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 2 })
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: [])).not_to be_ok
      expect(action.call(v: [1])).not_to be_ok
      expect(action.call(v: [1, 2])).to be_ok
    end

    it "points a dead presence:/tolerance combination at the working spelling" do
      expect { build(type: Array, presence: true, allow_nil: true) }
        .to raise_error(ArgumentError, /allow_empty: false/)
    end

    it "reaches the mirror cell through allow_nil: true, not just optional:" do
      action = build(type: Array, allow_nil: true, allow_empty: false)
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: [])).not_to be_ok
    end

    it "reaches the mirror cell through allow_blank: true, not just optional:" do
      action = build(type: Array, allow_blank: true, allow_empty: false)
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: [])).not_to be_ok
    end
  end

  # `allow_empty:` is not the only way a declaration can answer whether an empty value is admissible:
  # an explicit `presence:` occupies the very check the flag governs, and an author's own `length:` can
  # forbid, admit, or say nothing about size 0. Where another declaration already answers, the two
  # answers must agree; where none does, the flag is enforced on its own.
  describe "reconciling allow_empty: with a declaration that already answers the emptiness question" do
    describe "an explicit presence:" do
      it "rejects presence: false alongside allow_empty: false" do
        expect { build(type: Array, presence: false, allow_empty: false) }
          .to raise_error(ArgumentError, /presence:.*allow_empty: false/m)
      end

      it "rejects presence: true alongside allow_empty: true" do
        expect { build(type: Array, presence: true, allow_empty: true) }
          .to raise_error(ArgumentError, /presence:.*allow_empty: true/m)
      end

      it "rejects a blank-tolerant presence: alongside allow_empty: false" do
        expect { build(type: Array, presence: { allow_blank: true }, allow_empty: false) }
          .to raise_error(ArgumentError, /presence:.*allow_empty: false/m)
      end

      it "rejects a nil-tolerant-only presence: alongside allow_empty: true — it still rejects empty" do
        expect { build(type: Array, presence: { allow_nil: true }, allow_empty: true) }
          .to raise_error(ArgumentError, /presence:.*allow_empty: true/m)
      end

      it "permits presence: true alongside allow_empty: false as a redundant restatement" do
        action = build(type: Array, presence: true, allow_empty: false)
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).to be_ok
      end

      it "permits presence: false alongside allow_empty: true as a redundant restatement" do
        action = build(type: Array, presence: false, allow_empty: true)
        expect(action.call(v: [])).to be_ok
        expect(action.call(v: nil)).not_to be_ok
      end

      it "permits a blank-tolerant presence: alongside allow_empty: true" do
        expect(build(type: Array, presence: { allow_blank: true }, allow_empty: true).call(v: [])).to be_ok
      end

      it "defers to a length: floor that answers the question presence: false declined" do
        # `presence: false` drops the blank check, but the author's own floor still forbids empty — so
        # `allow_empty: false` is honored and there is nothing to reconcile.
        action = build(type: Array, presence: false, length: { minimum: 3 }, allow_empty: false)
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1, 2, 3])).to be_ok
      end

      it "reads no emptiness answer out of a presence: under a nil-tolerance, where it can never fire" do
        action = build(type: Array, optional: true, presence: false, allow_empty: false)
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).to be_ok
      end
    end

    # Deferring the axis to another spelling only settles it if that spelling is guaranteed to run.
    # An entry carrying its OWN if:/unless: is skipped whenever its condition says so, and one scoped to a
    # validation context never runs at all — so `allow_empty: false` keeps its own check alongside either,
    # rather than trusting a promise that can go quiet.
    describe "a deferral target that is not guaranteed to run" do
      it "keeps enforcing allow_empty: false alongside a length: floor whose own gate is closed" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 2, if: -> { false } })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1])).to be_ok # the author's floor is the one their gate closed
      end

      it "keeps the author's gated floor firing on its own terms when the gate is open" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 2, if: -> { true } })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1]).exception.message).to include("is too short")
        expect(action.call(v: [1, 2])).to be_ok
      end

      it "keeps enforcing allow_empty: false alongside a length: floor scoped to a validation context" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 2, on: :create })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
      end

      it "keeps enforcing allow_empty: false alongside a presence: whose own gate is closed" do
        action = build(type: Array, presence: { if: -> { false } }, allow_empty: false)
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1])).to be_ok
      end

      it "keeps enforcing allow_empty: false alongside a presence: scoped to a validation context" do
        action = build(type: Array, presence: { on: :create }, allow_empty: false)
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1])).to be_ok
      end

      # An inert entry supplies NO emptiness answer — not a permissive one either, so it cannot conflict
      # with the flag. The declaration is coherent and the flag simply carries the axis on its own.
      it "reads no answer at all out of a context-scoped length: that would otherwise admit an empty value" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 0, on: :create })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1])).to be_ok
      end

      it "reads no answer at all out of a context-scoped presence: alongside allow_empty: true" do
        action = build(type: Array, presence: { on: :create }, allow_empty: true)
        expect(action.call(v: [])).to be_ok
        expect(action.call(v: nil)).not_to be_ok
      end

      it "reads no answer at all out of a context-scoped, per-call length: minimum" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: :cap, on: :create })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
      end

      # A NON-inert entry still answers, in both polarities, so a real contradiction still raises.
      it "still raises for the same conflicts when the entry can run" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { minimum: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
        expect { build(type: Array, presence: true, allow_empty: true) }
          .to raise_error(ArgumentError, /presence:.*allow_empty: true/m)
      end

      # A DECLARATION-level gate is a different thing: it gates every validator in the declaration, the
      # emptiness check included, which is exactly what declaring it asks for.
      it "leaves a declaration-level gate governing the emptiness check too" do
        action = build(type: Array, optional: true, allow_empty: false, if: -> { false })
        expect(action.call(v: [])).to be_ok
      end

      it "still reads an answer out of a GATED entry, which a call may run" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { minimum: 0, if: :flag }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end
    end

    describe "an author-declared length:" do
      it "honors allow_empty: false alongside a length: that only caps the size" do
        action = build(type: Array, optional: true, allow_empty: false, length: { maximum: 3 })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1, 2])).to be_ok
        expect(action.call(v: [1, 2, 3, 4])).not_to be_ok
      end

      it "keeps the author's own violation message while naming emptiness for the empty value" do
        action = build(type: Array, optional: true, allow_empty: false, length: { maximum: 1 })
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1, 2]).exception.message).to include("is too long")
      end

      it "leaves an author-declared message: in charge of both violations" do
        action = build(type: Array, optional: true, allow_empty: false, length: { maximum: 1, message: "bad size" })
        expect(action.call(v: []).exception.message).to include("bad size")
        expect(action.call(v: [1, 2]).exception.message).to include("bad size")
      end

      it "honors allow_empty: false alongside an explicitly disabled length:" do
        action = build(type: Array, optional: true, allow_empty: false, length: false)
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).to be_ok
      end

      it "makes an author-declared floor fire on an empty value under optional:, which would otherwise tolerate blank" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 3 })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).not_to be_ok
        expect(action.call(v: [1, 2, 3])).to be_ok
      end

      it "rejects a length: minimum of 0 alongside allow_empty: false" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { minimum: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      # A `length:` that explicitly ADMITS an empty value contradicts the flag no matter what else happens to
      # enforce the axis — the inferred presence check honors the flag, but the declaration is still saying
      # two things, so the same pair raises in every arrangement rather than only under a tolerance.
      it "rejects a length: that admits an empty value with no tolerance declared either" do
        expect { build(type: Array, allow_empty: false, length: { minimum: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
        expect { build(type: Array, allow_empty: false, length: { maximum: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
        expect { build(type: Array, allow_empty: false, length: { minimum: 3, allow_blank: true }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      it "leaves a length: that names a real floor deferred to with no tolerance declared" do
        action = build(type: Array, allow_empty: false, length: { minimum: 2 })
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).not_to be_ok
        expect(action.call(v: [1, 2])).to be_ok
      end

      # An unverifiable floor is not a contradiction — it is a floor nothing here can read — so where the
      # inferred presence check already forbids empty there is nothing to reconcile and no reason to raise.
      it "accepts a per-call length: minimum where the inferred presence check carries the axis" do
        action = build(type: Array, allow_empty: false, length: { minimum: :cap })
        expect(action.call(v: [])).not_to be_ok
      end

      it "rejects a length: is: of 0 alongside allow_empty: false" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { is: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      it "rejects a length: range that starts at 0 alongside allow_empty: false" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { in: 0..3 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
        expect { build(type: Array, optional: true, allow_empty: false, length: { within: 0..3 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      it "rejects a length: maximum of 0 alongside allow_empty: false — only an empty value would pass" do
        expect { build(type: Array, optional: true, allow_empty: false, length: { maximum: 0 }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      it "rejects a length: carrying its own blank-tolerance alongside allow_empty: false" do
        expect { build(type: Array, allow_nil: true, allow_empty: false, length: { minimum: 3, allow_blank: true }) }
          .to raise_error(ArgumentError, /length:.*allow_empty: false/m)
      end

      # The axis leans only on a floor of a positive whole size — the one shape a schema floor can carry — so
      # a floor the runtime honors is never a floor the schema drops.
      #
      # ActiveModel accepts a non-negative Integer, `Float::INFINITY`, a Symbol or a Proc as a length bound,
      # so a fractional floor is a broken declaration whose ArgumentError surfaces at validation exactly as
      # it does without `allow_empty:`. The axis leans on no such floor, and does not preempt its error.
      it "leans on no fractional floor, which ActiveModel itself refuses as a bound" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 0.5 })
        expect(action.call(v: []).exception.message).to include("must be a non-negative Integer")
      end

      it "keeps its own check alongside a floor of no whole size, which no schema floor could carry" do
        action = build(type: Array, optional: true, allow_empty: false, length: { minimum: Float::INFINITY })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: []).exception.message).to include("can't be empty")
        expect(action.call(v: [1])).not_to be_ok # the author's own floor rejects every size
      end

      it "rejects a per-call length: minimum alongside allow_empty: false, which it cannot verify" do
        expect { build(type: Array, allow_nil: true, allow_empty: false, length: { minimum: :cap }) }
          .to raise_error(ArgumentError, /allow_empty: false.*length:/m)
      end

      it "accepts a length: range that starts above 0 alongside allow_empty: false" do
        action = build(type: Array, optional: true, allow_empty: false, length: { in: 1..3 })
        expect(action.call(v: nil)).to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).to be_ok
      end

      it "subjects a blank-but-not-empty String to the author's floor once empty is forbidden" do
        # `allow_empty: false` is what stops the entry standing aside for blank values, and a floor above 1
        # then judges `" "` on its size like any other non-nil value. Without an author floor the flag's own
        # floor of 1 still accepts `" "`, which is the emptiness axis being `empty?` rather than `blank?`.
        floored = build(type: String, optional: true, allow_empty: false, length: { minimum: 3 })
        expect(floored.call(v: " ")).not_to be_ok
        expect(floored.call(v: "abc")).to be_ok
        expect(build(type: String, optional: true, allow_empty: false).call(v: " ")).to be_ok
      end

      it "leaves a length: alone alongside allow_empty: true, which asks for nothing to be enforced" do
        # `allow_empty: true` suppresses the presence check axn would otherwise add; it makes no promise
        # about the author's own size constraint, which keeps rejecting the values it always rejected.
        action = build(type: Array, allow_empty: true, length: { minimum: 3 })
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1, 2, 3])).to be_ok
      end

      it "leaves a length: alone alongside allow_empty: false when the default presence check already forbids empty" do
        action = build(type: Array, allow_empty: false, length: { maximum: 3 })
        expect(action.call(v: nil)).not_to be_ok
        expect(action.call(v: [])).not_to be_ok
        expect(action.call(v: [1])).to be_ok
        expect(action.call(v: [1, 2, 3, 4])).not_to be_ok
      end
    end

    describe "a type that takes no default presence check" do
      it "enforces allow_empty: false on :params, which never gets one" do
        action = build(type: :params, allow_empty: false)
        expect(action.call(v: {})).not_to be_ok
        expect(action.call(v: { a: 1 })).to be_ok
        expect(action.call(v: nil)).not_to be_ok
      end

      it "leaves allow_empty: true on :params accepting an empty value" do
        action = build(type: :params, allow_empty: true)
        expect(action.call(v: {})).to be_ok
        expect(action.call(v: nil)).not_to be_ok
      end
    end
  end

  # A union's emptiness axis was unpinned: the declaration guard asks every member type for an empty
  # state, so a union mixing one in with one without is rejected outright rather than half-honored.
  describe "allow_empty: on a union type" do
    it "accepts a union whose every member has an empty state" do
      action = build(type: [Hash, Array], allow_empty: true)
      expect(action.call(v: {})).to be_ok
      expect(action.call(v: [])).to be_ok
      expect(action.call(v: [1])).to be_ok
      expect(action.call(v: nil)).not_to be_ok
      expect(action.call(v: 5)).not_to be_ok
    end

    it "rejects every member's empty value under the mirror cell" do
      action = build(type: [Hash, Array], optional: true, allow_empty: false)
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: {})).not_to be_ok
      expect(action.call(v: [])).not_to be_ok
      expect(action.call(v: { a: 1 })).to be_ok
      expect(action.call(v: [1])).to be_ok
    end

    it "rejects a union with one member that cannot be empty, in either polarity" do
      expect { build(type: [Array, Integer], allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*Integer.*cannot be empty/)
      expect { build(type: [Array, Integer], optional: true, allow_empty: false) }
        .to raise_error(ArgumentError, /allow_empty:.*Integer.*cannot be empty/)
    end

    it "rejects a nullable union, whose NilClass member has no empty state" do
      expect { build(type: [Array, NilClass], allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*NilClass.*cannot be empty/)
    end
  end

  describe "a nil rejected by type produces exactly one error" do
    let(:action) do
      build(type: Hash, allow_empty: true, validate: ->(h) { "values must be Integer" unless h.values.all?(Integer) })
    end

    it "reports the type error and not a crashed custom validator" do
      message = action.call(v: nil).exception.message

      expect(message).to include("is not a Hash")
      expect(message).not_to include("failed validation")
      expect(message).not_to include("undefined method")
    end

    it "still runs the custom validator for a non-nil value" do
      expect(action.call(v: { a: 1 })).to be_ok
      expect(action.call(v: { a: "x" }).exception.message).to include("values must be Integer")
    end

    it "still reports both when two independent validators reject the same non-nil value" do
      klass = build(type: Array, of: Integer, allow_empty: true, validate: ->(_a) { "always fails" })
      message = klass.call(v: ["x"]).exception.message

      expect(message).to include("element at index 0 is not a Integer")
      expect(message).to include("always fails")
    end

    it "leaves the other validators' nil rejections in force when the type itself admits nil" do
      # `NilClass` among the declared klasses means the type check ACCEPTS nil — the nil is no type
      # defect at all, so the default presence check is the only thing rejecting it and must keep doing so.
      action = build(type: [Array, NilClass])

      result = action.call(v: nil)
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("V can't be blank")
      expect(action.call(v: [1])).to be_ok
    end

    it "preserves a strict validator's raise instead of suppressing it" do
      # A strict entry RAISES rather than recording an error, and EachValidator's allow_nil skip runs
      # BEFORE validate_each — so relaxing it would swallow the raise, not just drop a duplicate message.
      # True here because presence forwards `strict:` into `errors.add`; none of axn's own custom
      # validators (type/of/validate/model/shape) do, so a `strict:` entry among THEM never raises and
      # this guard's stand-down preserves baseline behavior for them rather than suppressing anything.
      # Pins the exception CLASS, which is what a caller (e.g. fails_on) keys on. Both tiers, because
      # strictness is per entry: `strict:` on the declaration, and `strict:` on the entry itself.
      declaration_tier = build(type: String, strict: true).call(v: nil)
      expect(declaration_tier.exception).to be_a(ActiveModel::StrictValidationFailed)

      entry_tier = build(type: String, presence: { strict: true }).call(v: nil)
      expect(entry_tier.exception).to be_a(ActiveModel::StrictValidationFailed)

      custom_class = build(type: String, strict: ArgumentError).call(v: nil)
      expect(custom_class.exception).to be_a(ArgumentError)
    end

    it "still collapses the duplicate messages when strict: is falsy" do
      # `strict: false` is not strict at either tier, so the collapse must still apply — standing down
      # there would silently restore the duplicate messages this behavior exists to remove.
      expect(build(type: String, strict: false).call(v: nil).exception.message).to eq("V is not a String")
      expect(build(type: String, presence: { strict: false }).call(v: nil).exception.message).to eq("V is not a String")

      # AM composes each validator's options as `declaration_defaults.merge(entry_options)`, so the
      # entry's own `strict:` overrides the declaration's — including overriding it with a falsy one.
      overridden = build(type: String, strict: true, presence: { strict: false }).call(v: nil)
      expect(overridden.exception).to be_a(Axn::InboundValidationError)
      expect(overridden.exception.message).to eq("V is not a String")
    end

    it "leaves the other validators' nil rejections in force when the type entry is scoped to a context" do
      # An `on:` INSIDE the type bag is ActiveModel's validation-context option, and axn validates with no
      # context — so that type check never runs on any call and its nil verdict is vacuous. The presence
      # check is the only thing rejecting a nil, and must keep doing so. (A declaration-level `on:` is
      # axn's subfield parent, something else entirely — covered by the subfield specs.)
      action = build(type: { klass: String, on: :create })

      result = action.call(v: nil)
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("V can't be blank")
      expect(action.call(v: "x")).to be_ok
    end

    it "leaves the other validators' nil rejections in force when the type check is gated" do
      # A closed gate skips the type check entirely, so its nil verdict is not the field's whole account —
      # the ungated presence check is what keeps a nil out, and must not be given nil-tolerance.
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean
        expects :v, type: { klass: String, if: :flag }, presence: true
        def call = nil
      end

      result = klass.call(flag: false, v: nil)
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("V can't be blank")
      expect(klass.call(flag: false, v: "x")).to be_ok
    end
  end
end
