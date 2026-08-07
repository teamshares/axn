# frozen_string_literal: true

require "benchmark"
require "open3"

# A declared name becomes a JSON property name — in the reflected schema for an inbound field, in
# serialized output for an outbound one — so it carries the same UTF-8 promise the serializer enforces on a
# Hash key. Two names that collapse onto one property, and a name with no UTF-8 rendering at all, are
# rejected when the class is defined: both are knowable from the declarations alone, and by the time a call
# or a serializing adapter would notice, the business logic and its side effects have already run.
RSpec.describe "declaration-time property name collisions" do
  # Two distinct Symbols, one JSON property: the same text in two encodings. Symbols carry bytes plus an
  # encoding, while a property name is text, so these are separate Hash keys and one property.
  def utf8_name = :café
  def latin1_name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

  # Bytes with no UTF-8 rendering at all. ASCII-8BIT is mandatory here (see the plan's fixture note).
  def unrenderable_name = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym

  # The two property-name rules are judged on the JSON projection a name would appear in, so they run when one
  # is first demanded rather than when the class is defined. An example therefore declares AND projects; this
  # keeps that one behavior instead of two steps.
  #
  # Both projections are demanded, so an inbound or an outbound collision surfaces from the same call — an
  # example does not have to know which side its fixture lands on. Rules that are NOT projection-gated (a
  # duplicate field under one route, an `exposes` field name's renderability, a member name's type, the
  # shape-graph traversal guards) raise during the `build_axn` inside, so examples asserting those keep using
  # `build_axn` directly and still prove they fire at declaration.
  def project_axn(&declaration)
    build_axn(&declaration).tap do |klass|
      klass.input_schema
      klass.output_schema
    end
  end

  # A shape member that is NOT a ShapeConfig — the duck-typing tolerance ShapeValidator documents (only
  # `#field` and `#validations` are required). It never routes through ShapeConfig's constructor, so its name
  # is never normalized, which makes it the one route by which a caller-supplied name still reaches the
  # guards as itself.
  def duck_typed_member(name)
    Class.new do
      define_method(:field) { name }
      def validations = {}
      def metadata = {}
      def description = nil
      def optional? = true
    end.new
  end

  # The rules run when a projection is first demanded, not when the class is defined. That is the whole point of
  # the design: nothing but a projection can be harmed by a colliding or unrenderable name, so an axn that never
  # projects is not broken by one, and the promise is stated where it is true.
  describe "when the rules run" do
    # Two shape members whose names canonicalize alike. Chosen because no eager rule sees it — the syntactic
    # duplicate check keys on `to_sym`, so these are two distinct keys to it, and only the emitted-property walk
    # judges them.
    def colliding_shape
      utf8 = utf8_name
      latin1 = latin1_name
      build_axn do
        expects(:payload, type: Hash) do
          field utf8, type: String
          field latin1, type: Integer
        end
        exposes :out, optional: true
        define_method(:call) { expose(out: 1) }
      end
    end

    it "declares a colliding contract cleanly, and the action still works" do
      klass = nil

      expect { klass = colliding_shape }.not_to raise_error
      expect(klass.call(payload: { utf8_name => "x", latin1_name => 2 })).to be_ok
    end

    it "raises when input_schema is first demanded" do
      klass = colliding_shape

      expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    # A verdict is recorded only after both rules pass, so a failure is never memoized as success. A swallowed
    # second call would be the worst outcome available here: the contract would look valid from then on.
    it "raises again on a second demand rather than memoizing the failure" do
      klass = colliding_shape

      expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError)
      expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError)
    end

    it "raises when output_schema is first demanded, for an outbound collision" do
      utf8 = utf8_name
      latin1 = latin1_name
      klass = build_axn do
        exposes(:payload, type: Hash) do
          field utf8, type: String
          field latin1, type: Integer
        end
      end

      expect { klass.output_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    # `render` builds no schema of its own, so it is a trigger by construction rather than by accident: an
    # adapter that only ever renders would otherwise meet the collision as a runtime serializer error.
    it "raises when a Result is rendered, for an outbound collision" do
      utf8 = utf8_name
      latin1 = latin1_name
      klass = build_axn do
        exposes(:payload, type: Hash) do
          field utf8, type: String, optional: true
          field latin1, type: Integer, optional: true
          field :ok, type: String
        end
        define_method(:call) { expose(payload: { ok: "x" }) }
      end
      result = klass.call

      expect(result).to be_ok
      expect { Axn::Extensions::Serialization.render(result) }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    # A projection that is BUILT is validated, every time. The memo cannot be trusted to stand in for that: a
    # caller holding the mutable `shape:` graph it declared with can change what the schema emits without
    # changing any config array, so a verdict keyed on config identity would be stale while the rebuilt schema
    # came back unvalidated. Validating what was just built costs a fraction of the build it follows.
    it "validates every projection it builds, not just the first" do
      klass = build_axn do
        expects :a, optional: true
        exposes :b, optional: true
      end
      walks = 0
      allow(Axn::Internal::Reflection::PropertyNames).to receive(:reject_colliding_emitted_properties!).and_wrap_original do |original, *args, &block|
        walks += 1
        original.call(*args, &block)
      end

      3.times { klass.input_schema }
      3.times { klass.output_schema }

      expect(walks).to eq(6)
    end

    # `render` is the one path that memoizes, because it builds an output schema solely to validate and would
    # otherwise pay for one on every call. Measured at roughly double the cost of a render without it.
    it "establishes render's outbound verdict once per class" do
      klass = build_axn do
        exposes :b, optional: true
        define_method(:call) { expose(b: 1) }
      end
      result = klass.call
      walks = 0
      allow(Axn::Internal::Reflection::PropertyNames).to receive(:reject_colliding_emitted_properties!).and_wrap_original do |original, *args, &block|
        walks += 1
        original.call(*args, &block)
      end

      3.times { Axn::Extensions::Serialization.render(result) }

      expect(walks).to eq(1)
    end

    it "re-validates after the contract grows" do
      klass = build_axn { expects :a, optional: true }
      klass.input_schema
      latin1 = latin1_name

      klass.expects(:payload, type: Hash) do
        field :ok, type: String
        field latin1, type: Integer
      end

      expect { klass.input_schema }.not_to raise_error
    end

    # A subclass holds its own ivars, so it cannot inherit a clean verdict — which matters because the contract
    # is copy-on-write and a subclass that declares nothing shares its parent's config arrays.
    it "does not let a subclass inherit a verdict for a contract it then changes" do
      parent = build_axn { expects :a, optional: true }
      parent.input_schema
      utf8 = utf8_name
      latin1 = latin1_name

      child = Class.new(parent) do
        expects(:payload, type: Hash) do
          field utf8, type: String
          field latin1, type: Integer
        end
      end

      expect { child.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
      expect { parent.input_schema }.not_to raise_error
    end
  end

  # One example per projection-gated rule pinning the EXACT class and the FULL message, so moving the trigger
  # cannot have quietly reduced what is checked. Every other example asserts a fragment, which is the right
  # granularity for them; these two are the anchors.
  describe "the exact errors the two rules raise" do
    it "reports a collision with its full message" do
      utf8 = utf8_name
      latin1 = latin1_name
      klass = build_axn do
        expects(:payload, type: Hash) do
          field utf8, type: String
          field latin1, type: Integer
        end
      end

      expect { klass.input_schema }.to raise_error(
        Axn::ContractViolation::DuplicateFieldError,
        'Duplicate shape member declared: :café and :"caf\xE9" both render as the JSON property "café", so the ' \
        "reflected schema would emit it twice. Declare them under names that stay distinct once converted to UTF-8.",
      )
    end

    it "reports an unrenderable name with its full message" do
      name = unrenderable_name
      klass = build_axn { expects(:payload, type: Hash) { field name, type: String } }

      expect { klass.input_schema }.to raise_error(
        ArgumentError,
        'a shape member name becomes a JSON property name, and :"bad\xFF" holds bytes that have no UTF-8 ' \
        "rendering — JSON is a UTF-8 format, so `JSON.generate` refuses such a property name outright. " \
        "Declare it under a UTF-8 name.",
      )
    end
  end

  # A contract must not change after the class is declared, so a raw `shape:` is deep-copied at declaration.
  # Storing the caller's object instead aliased it: a builder Hash reused across two declarations gave the FIRST
  # class members appended after it was already declared. Copying rather than freezing is what lets the ordinary
  # builder pattern keep working.
  describe "a contract is fixed at declaration" do
    def payload_props(klass) = klass.input_schema.dig(:properties, :payload, :properties).keys

    it "does not let a class gain members appended after it was declared" do
      builder = { members: [], container: Hash }
      builder[:members] << Axn::Core::Contract::ShapeConfig.new(field: :one, validations: {})
      first = build_axn { expects :payload, type: Hash, shape: builder }
      builder[:members] << Axn::Core::Contract::ShapeConfig.new(field: :two, validations: {})
      second = build_axn { expects :payload, type: Hash, shape: builder }

      expect(payload_props(first)).to eq([:one])
      expect(payload_props(second)).to eq(%i[one two])
    end

    it "copies a nested raw shape too" do
      inner = { members: [Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: {})], container: Hash }
      outer = { members: [Axn::Core::Contract::ShapeConfig.new(field: :mid, validations: { type: { klass: Hash }, shape: inner })],
                container: Hash }
      klass = build_axn { expects :payload, type: Hash, shape: outer }
      before = klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys

      inner[:members] << Axn::Core::Contract::ShapeConfig.new(field: :sneaked, validations: {})

      expect(before).to eq([:deep])
      expect(klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys).to eq([:deep])
    end

    # Copying, not freezing: freezing an object the caller owns would raise FrozenError on the builder pattern
    # above, which copying instead makes behave the way its author meant.
    it "leaves the caller's own object unfrozen and reusable" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :s, validations: {})], container: Hash }
      build_axn { expects :payload, type: Hash, shape: }

      expect(shape).not_to be_frozen
      expect(shape[:members]).not_to be_frozen
      expect { shape[:members] << Axn::Core::Contract::ShapeConfig.new(field: :later, validations: {}) }.not_to raise_error
    end

    it "still lets two axns share one shape Hash" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :s, validations: {})], container: Hash }

      expect(payload_props(build_axn { expects :payload, type: Hash, shape: })).to eq([:s])
      expect(payload_props(build_axn { expects :payload, type: Hash, shape: })).to eq([:s])
    end

    # A members list that answers two reads differently is a caller contradicting itself, and the answer is to
    # ask exactly once: checking the graph, bounding its size, and copying it are ONE walk, so no later layer
    # can be handed members a check never saw. Measured rather than asserted, at two nesting levels.
    describe "reading a caller's members list" do
      # `each` is the only method the walk uses (see Internal::ShapeGraph), so counting it counts the walks.
      def counting_list(*members)
        Class.new do
          attr_reader :walks

          define_method(:initialize) do |items|
            @items = items
            @walks = 0
          end

          define_method(:each) do |&block|
            @walks += 1
            @items.each(&block)
            self
          end
        end.new(members)
      end

      it "reads it exactly once per declaration, at every level of nesting" do
        inner = counting_list(Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: {}))
        outer = counting_list(Axn::Core::Contract::ShapeConfig.new(field: :mid,
                                                                   validations: { type: { klass: Hash }, shape: { members: inner, container: Hash } }))
        klass = build_axn { expects :payload, type: Hash, shape: { members: outer, container: Hash } }

        expect([outer.walks, inner.walks]).to eq([1, 1])

        klass.input_schema
        klass.output_schema

        expect([outer.walks, inner.walks]).to eq([1, 1])
      end

      it "holds the answer that one read gave, when a later read would answer differently" do
        list = Class.new do
          def initialize = @reads = 0

          def each(&block)
            @reads += 1
            [Axn::Core::Contract::ShapeConfig.new(field: :"read#{@reads}", validations: {})].each(&block)
            self
          end
        end.new
        klass = build_axn { expects :payload, type: Hash, shape: { members: list, container: Hash } }

        expect(payload_props(klass)).to eq([:read1])
      end

      # The one case that still surfaces at declaration, and deliberately: a list that cannot be read AT ALL
      # leaves nothing to declare, so its exception propagates to where the author is standing rather than
      # being deferred to the first projection.
      it "raises at declaration when the list cannot be read at all" do
        list = Class.new { def each = raise(TypeError, "no members for you") }.new

        expect { build_axn { expects :payload, type: Hash, shape: { members: list, container: Hash } } }
          .to raise_error(TypeError, "no members for you")
      end
    end

    # Reading a member's name once is not enough on its own: CANONICALIZING it (`to_sym`) is a second dispatch
    # on the same caller object, and a String subclass answering it differently gave the duplicate check one
    # property name while the stored `ShapeConfig` took another. Two declared members were then stored under one
    # property, the schema emitted one, and nothing raised — the exact collapse this whole file exists to
    # reject, reached by a name that agreed with itself only once.
    describe "canonicalizing a caller's member name" do
      # A name whose `to_sym` answers with each of `answers` in turn, and repeats the last one after that. The
      # STRING content is a third spelling on purpose, so a conversion taken from the bytes rather than from
      # this reader is visible as itself rather than as one of the answers.
      def flipping_name(*answers)
        Class.new(String) do
          define_method(:initialize) do |content|
            @answers = answers
            @reads = 0
            super(content)
          end

          def to_sym
            @reads += 1
            @answers[[@reads - 1, @answers.size - 1].min]
          end

          attr_reader :reads
        end.new("bytes")
      end

      def member(name, validations = {}) = Struct.new(:field, :validations).new(name, validations)

      it "converts it exactly once, and keys the member on the answer the guard judged" do
        name = flipping_name(:alpha, :collide)
        shape = { members: [member(name), member(:collide)], container: Hash }
        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(name.reads).to eq(1)
        expect(payload_props(klass)).to eq(%i[alpha collide])
        expect(klass.internal_field_configs.first.validations[:shape][:members].map(&:field)).to eq(%i[alpha collide])
      end

      # The other direction of the same property: when the ONE conversion is what collides, it is rejected — so
      # the guard's verdict and the stored contract are the same fact, whichever way the name answers.
      it "rejects the duplicate when that one answer is the colliding one" do
        name = flipping_name(:collide, :alpha)
        shape = { members: [member(name), member(:collide)], container: Hash }

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate shape member declared/)
      end

      it "holds at every level of nesting" do
        name = flipping_name(:alpha, :collide)
        nested = { members: [member(name), member(:collide)], container: Hash }
        shape = { members: [member(:mid, { type: { klass: Hash }, shape: nested })], container: Hash }
        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(name.reads).to eq(1)
        expect(klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys).to eq(%i[alpha collide])
      end

      # A String subclass is not the defect — answering differently on two reads is. One with an ordinary
      # (or an unusual but STABLE) `to_sym` declares exactly as the name it converts to.
      it "still declares a String subclass whose conversion is stable" do
        shape = { members: [member(Class.new(String) { def to_sym = :renamed }.new("ignored"))], container: Hash }

        expect(payload_props(build_axn { expects :payload, type: Hash, shape: })).to eq([:renamed])
      end
    end

    # A duck-typed member is snapshotted into axn's own `ShapeConfig` like any other, so the nested shape it
    # carries is copied too — there is no member the copy stops at.
    it "copies a nested shape carried by a duck-typed member" do
      inner = { members: [Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: {})], container: Hash }
      duck = Class.new do
        define_method(:initialize) { |validations| @validations = validations }
        def field = :mid
        attr_reader :validations

        def metadata = {}
        def description = nil
        def optional? = true
      end.new({ type: { klass: Hash }, shape: inner })
      klass = build_axn { expects :payload, type: Hash, shape: { members: [duck], container: Hash } }
      klass.input_schema

      inner[:members] << Axn::Core::Contract::ShapeConfig.new(field: :sneaked, validations: {})

      expect(klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys).to eq(%i[deep])
    end

    # What a stored graph can still be — untraversable, because a field config was assigned onto a class rather
    # than declared — is covered in `stored_shape_traversal_spec.rb`, since it is about whether a graph axn holds
    # can be walked rather than about the names it emits.

    # The same aliasing existed in the other option containers axn stores.
    # No tolerance flag on purpose: `optional:`/`allow_nil:`/`allow_blank:` push tolerance into each validator,
    # which rebuilds the option bags as a side effect and would detach this one incidentally — hiding the
    # aliasing rather than testing it.
    it "does not let a mutated of: bag change a declared element type" do
      options = { klass: String }
      klass = build_axn { expects :list, type: Array, of: options }
      before = klass.input_schema.dig(:properties, :list, :items)

      options[:klass] = Integer

      expect(klass.input_schema.dig(:properties, :list, :items)).to eq(before)
    end

    # This one changes RUNTIME behavior, not just a reflected schema: it swapped which validator a declared
    # field runs.
    it "does not let a mutated validate: bag change which validator runs" do
      bag = { with: ->(value) { "bad" if value == 1 } }
      klass = build_axn { expects :n, validate: bag }

      expect(klass.call(n: 1)).not_to be_ok
      bag[:with] = ->(_value) {}
      expect(klass.call(n: 1)).not_to be_ok
    end

    it "does not let a mutated inclusion: list widen a declared enum" do
      values = %w[a b]
      klass = build_axn { expects :a, inclusion: { in: values }, optional: true }
      before = klass.input_schema.dig(:properties, :a, :enum)

      values << "c"

      expect(klass.input_schema.dig(:properties, :a, :enum)).to eq(before)
    end

    # A raw member's options are detached on exactly the same terms as a field's. They were not, for a reason
    # worth naming: the member path skipped the copy whenever no KEY needed canonicalizing, and "needs no key
    # change" is a different question from "needs no copy".
    describe "a raw shape member's own options" do
      def member_axn(validations)
        member = Axn::Core::Contract::ShapeConfig.new(field: :choice, validations:)
        build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
      end

      it "does not let a mutated inclusion: list widen a member's enum" do
        allowed = %w[a b]
        klass = member_axn({ inclusion: { in: allowed } })

        expect(klass.call(payload: { choice: "c" })).not_to be_ok
        allowed << "c"
        expect(klass.call(payload: { choice: "c" })).not_to be_ok
      end

      it "does not let a mutated option bag change what a member validates" do
        bag = { in: %w[a b] }
        klass = member_axn({ inclusion: bag })

        expect(klass.call(payload: { choice: "c" })).not_to be_ok
        bag[:in] = %w[a b c]
        expect(klass.call(payload: { choice: "c" })).not_to be_ok
      end

      # The same two controls the field path established, so a member is held to exactly what a field is.
      it "keeps a subclass that adds no code of its own, whose copy is faithful" do
        values = Class.new(Array).new.push("a", "b")
        klass = member_axn({ inclusion: { in: values } })

        expect(klass.call(payload: { choice: "a" })).to be_ok
        expect(klass.call(payload: { choice: "z" })).not_to be_ok
      end

      it "rejects a container that answers membership with its own code" do
        values = Class.new(Array) { def include?(_value) = true }.new.push("a", "b")

        expect { member_axn({ inclusion: { in: values } }) }
          .to raise_error(ArgumentError, /defines methods of its own/)
      end

      it "rejects a container that defines a duplication hook" do
        values = Class.new(Array) do
          def initialize_dup(source)
            super
            clear
          end
        end.new.push("a", "b")

        expect { member_axn({ inclusion: { in: values } }) }
          .to raise_error(ArgumentError, /defines methods of its own/)
      end
    end

    # A container is detached whatever it says about itself and whatever its copiers do. Each of these three
    # subclasses defeated the detach in a different way while the plain-Array cases above were copied correctly
    # — the same lying-subclass class the shape guards close, one layer over.
    describe "an option container that lies about itself" do
      def accepts_c?(klass) = klass.call(choice: "c").ok?

      def declared_with(values)
        build_axn { expects :choice, inclusion: { in: values } }
      end

      # Neither of these two can escape the detach by lying — the type test is `case`/`when` and the copy is a
      # bound `Kernel#dup` — but each is a container that answers with CODE OF ITS OWN, so each is now refused
      # before either lie is consulted.
      it "refuses one that denies its own class rather than storing it aliased" do
        values = Class.new(Array) { def is_a?(other) = Array.equal?(other) ? false : super }.new(%w[a b])

        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own/)
      end

      it "refuses one whose dup returns itself" do
        values = Class.new(Array) { def dup = self }.new(%w[a b])

        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own/)
      end

      it "detaches a bag whose transform_values hands back the receiver" do
        bag = Class.new(Hash) { def transform_values(&) = self }.new
        bag[:in] = %w[a b]
        klass = build_axn { expects :choice, inclusion: bag }

        expect(accepts_c?(klass)).to be(false)
        bag[:in] << "c"
        expect(accepts_c?(klass)).to be(false)
      end

      # A container that answers with code of its own is refused rather than copied-and-checked. What that code
      # does in the copy cannot be established without running it, and every narrower rule was defeated one case
      # later — two rounds of verifying the copy, then gating on the duplication hooks (see the rows below, in
      # the order the counterexamples arrived) — so ownership of everything it answers with is the verdict.
      it "rejects one that defines a duplication hook at all" do
        values = Class.new(Array) do
          def initialize_dup(source)
            super
            clear
          end
        end.new.push("a", "b")

        expect { declared_with(values) }
          .to raise_error(ArgumentError, /defines methods of its own \(`:initialize_dup`\).*Supply a plain Array, or freeze/m)
      end

      # The first case verification missed: the elements are not the whole contract. An `inclusion:` set answers
      # membership with its OWN `include?`, which may be derived from state the elements do not determine, so a
      # copy holding the identical elements can still REJECT what the original accepts.
      it "rejects one whose duplication drops the state its membership is derived from" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @index = to_a.map(&:to_s)
          end

          def initialize_dup(source)
            super
            @index = [] # the elements survive; the index `include?` reads does not
          end

          def include?(value) = (@index || []).include?(value.to_s)
        end.new(%w[a b])

        expect(values.include?("a")).to be(true)
        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own/)
      end

      # The second, which is why no probe closes this: membership can accept values that are not elements, so
      # asking the copy `include?` about each ELEMENT agrees with the original while the copy has silently
      # stopped accepting the aliases the original accepted. The accepted set is whatever arbitrary code says.
      it "rejects one whose duplication drops an alias index no element-based probe can see" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @aliases = { "alias" => "canon" }
          end

          def initialize_dup(source)
            super
            @aliases = {} # every ELEMENT still answers `include?`; only the aliases stop
          end

          def include?(value) = to_a.include?(value) || @aliases.key?(value.to_s)
        end.new(%w[canon])

        expect(values.include?("canon")).to be(true)
        expect(values.include?("alias")).to be(true)
        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own/)
      end

      # The third counterexample, and the one that moved the gate from the duplication hooks to every method a
      # container answers with: NO hook at all, native duplication throughout, and the copy still disagrees.
      # `dup` copies the elements but SHARES the instance variables, so a membership derived from identity is
      # carried into a copy that reads it as false — and axn then rejected a value the caller declared as
      # accepted. What a faithful copy needs is not a faithful duplication hook; it is that the copied state
      # (the elements) determines every answer, which holds only when the answers are Ruby's own.
      it "rejects one whose membership is derived from its own identity, with no duplication hook at all" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @me = self
          end

          def include?(value) = @me.equal?(self) && to_a.include?(value)
        end.new(%w[ok])

        expect(values.include?("ok")).to be(true)
        expect(values.dup.include?("ok")).to be(false) # the copy Ruby's own `dup` produces already disagrees
        expect { declared_with(values) }
          .to raise_error(ArgumentError, /defines methods of its own \(`:include\?`, `:initialize`\).*freeze/m)
      end

      it "accepts that same container frozen, and answers membership exactly as it declared" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @me = self
          end

          def include?(value) = @me.equal?(self) && to_a.include?(value)
        end.new(%w[ok]).freeze
        klass = declared_with(values)

        expect(klass.call(choice: "ok")).to be_ok
        expect(klass.call(choice: "z")).not_to be_ok
      end

      # Where the lookup goes decides this one, the other way round from the duplication hooks: `dup` reaches
      # hooks on the COPY's class, but a consumer asks the ORIGINAL, and a copy carries no singleton — so a
      # singleton `include?` is code the original answers with and the copy cannot. Asking the class alone left
      # this open on a plain Array.
      it "rejects a plain Array whose SINGLETON answers membership" do
        values = %w[a b]
        values.define_singleton_method(:include?) { |_value| true }

        expect(values.include?("z")).to be(true)
        expect(values.dup.include?("z")).to be(false)
        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own \(`:include\?`\)/)
      end

      # An extended module lives in the same place (the singleton class's ancestry) and is dropped by `dup` the
      # same way, so one walk answers both.
      it "rejects one whose membership comes from a module extended onto it" do
        values = %w[a b]
        values.extend(Module.new { def include?(_value) = true })

        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own \(`:include\?`\)/)
      end

      # The same root, aliasing rather than divergence: `dup` shares the ivars, so a membership reading one is
      # still the caller's to change after the class is declared — which is the whole thing the copy buys.
      it "rejects one whose membership reads an instance variable the copy still shares" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @extra = []
          end

          attr_reader :extra

          def include?(value) = to_a.include?(value) || @extra.include?(value)
        end.new(%w[a])

        expect { declared_with(values) }.to raise_error(ArgumentError, /defines methods of its own/)
      end

      # `include?` is what an `inclusion:` set is asked, but it is not the only thing a stored option container
      # is asked, and the gate is not a list of the predicates one consumer happens to dispatch: `type:` reaches
      # the same copy and is read with `Array(...)`/`any?`, so an identity-dependent `any?` made a declared
      # `type: String` reject the String it was declared for.
      it "rejects a type: container that decides with its own any?" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @me = self
          end

          def any?(&) = @me.equal?(self) ? super : false
        end.new([String])

        expect { build_axn { expects :choice, type: values } }
          .to raise_error(ArgumentError, /the `type:` container.*defines methods of its own \(`:any\?`, `:initialize`\)/m)
      end

      it "rejects an of: element-type container on the same terms" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @me = self
          end

          def any?(&) = @me.equal?(self) ? super : false
        end.new([String])

        expect { build_axn { expects :choice, type: Array, of: { klass: values } } }
          .to raise_error(ArgumentError, /the `of: \{ klass: … \}` container.*defines methods of its own/m)
      end

      # `exclusion:` reaches the same detach and the same ActiveModel `include?` — with the verdict inverted, so
      # a copy that answers false ADMITS the value the declaration excluded.
      it "rejects an exclusion: container that answers with its own code, and accepts it frozen" do
        klass = Class.new(Array) do
          def initialize(*args)
            super
            @me = self
          end

          def include?(value) = @me.equal?(self) && to_a.include?(value)
        end

        expect { build_axn { expects :choice, exclusion: { in: klass.new(%w[bad]) } } }
          .to raise_error(ArgumentError, /the `exclusion: \{ in: … \}` container.*defines methods of its own/m)

        frozen = build_axn { expects :choice, exclusion: { in: klass.new(%w[bad]).freeze } }
        expect(frozen.call(choice: "bad")).not_to be_ok
        expect(frozen.call(choice: "fine")).to be_ok
      end

      # The bounded escape hatch, and what keeps the over-rejection honest: the copy exists so a caller's later
      # mutation cannot change a declared contract, and a frozen container cannot be mutated — so it is stored
      # as-is, hook and all, and its own `include?` (index rebuilt in `initialize`) is what the contract asks.
      it "accepts a frozen container that defines a duplication hook, and honors its membership" do
        values = Class.new(Array) do
          def initialize(*args)
            super
            @index = each_with_object({}) { |value, hash| hash[value] = true }
          end

          def initialize_dup(source)
            super
            @index = {}
          end

          def include?(value) = @index.key?(value)
        end.new(%w[x y]).freeze
        klass = declared_with(values)

        expect(klass.call(choice: "x")).to be_ok
        expect(klass.call(choice: "z")).not_to be_ok
      end

      # A singleton duplication hook is refused too, and by the general rule rather than by a claim about that
      # hook: `dup` cannot reach it (the copy carries no singleton), but the rule asked is "does this container
      # answer anything with its own code", and one carve-out for a method nothing dispatches would be another
      # guarantee about foreign code to get wrong. `freeze` covers it, as it covers every other own method.
      it "refuses one whose SINGLETON defines a duplication hook" do
        values = %w[a b]
        values.define_singleton_method(:initialize_dup) { |_source| clear }

        expect { declared_with(values) }
          .to raise_error(ArgumentError, /defines methods of its own \(`:initialize_dup`\)/)
      end

      # A frozen PLAIN container is stored as-is too — the copy is what a mutable one is protected with, and
      # there is nothing here to protect against.
      it "stores a frozen plain Array without copying it" do
        values = %w[x y].freeze
        klass = declared_with(values)

        expect(klass.internal_field_configs.first.validations.dig(:inclusion, :in)).to be(values)
        expect(klass.call(choice: "x")).to be_ok
        expect(klass.call(choice: "z")).not_to be_ok
      end

      # The refusal must not over-reach either: a subclass that adds no code of its own is copied exactly as a
      # plain Array is, and the copy keeps the caller's CLASS (which is also why reflection still withholds an
      # enum for it — it does that for anything but an exact Array).
      it "copies a subclass that adds no code of its own, and keeps its class" do
        subclass = Class.new(Array)
        values = subclass.new(%w[a b])
        klass = declared_with(values)
        stored = klass.internal_field_configs.first.validations.dig(:inclusion, :in)

        expect(stored).not_to be(values)
        expect(stored.class).to be(subclass)
        expect(accepts_c?(klass)).to be(false)
        values << "c"
        expect(accepts_c?(klass)).to be(false)
        expect(klass.call(choice: "a")).to be_ok
        expect(klass.input_schema.dig(:properties, :choice, :enum)).to be_nil
      end

      # A method name reaches prose like every other name this PR routes through one renderer: a container
      # defining a method whose bytes have no UTF-8 rendering would otherwise raise Encoding::CompatibilityError
      # from inside the declaration error it caused.
      it "names an offending method whose bytes have no UTF-8 rendering, escaped" do
        method_name = unrenderable_name
        values = Class.new(Array) { define_method(method_name) { 1 } }.new(%w[a])
        name = utf8_name

        expect { build_axn { expects name, inclusion: { in: values } } }
          .to raise_error(ArgumentError, /defines methods of its own \(`:"bad\\xFF"`\)/)
      end

      # The baseline for "Ruby's own" is what ::Array itself answers with, read from its ancestors rather than
      # assumed to be the class alone — so a module PREPENDED to Array (which sits ahead of it in every Array's
      # ancestry) is Ruby's own here, instead of refusing every container in the app that did it. In a fresh
      # process, since prepending to Array cannot be undone for the rest of the suite.
      it "still copies a plain Array in a process where a module is prepended to Array" do
        script = <<~RUBY
          $LOAD_PATH.unshift("lib")
          require "logger"
          require "axn"
          Axn.config.logger = Logger.new(IO::NULL)
          module ArrayPatch
            def include?(value) = super
          end
          Array.prepend(ArrayPatch)
          klass = Class.new do
            include Axn
            expects :choice, inclusion: { in: %w[a b] }
            def call = nil
          end
          print [klass.call(choice: "a").ok?, klass.call(choice: "c").ok?].inspect
        RUBY
        out, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: File.expand_path("../../../..", __dir__))

        expect([out, status.success?]).to eq(["[true, false]", true])
      end

      # The other residue, and the same one-level depth the copy promises: freezing a container freezes its own
      # slots, not the objects its ivars point at, so a frozen container deriving membership from a mutable index
      # is still the caller's to widen. Recorded, because the escape hatch must not read as more than it is.
      it "records the residue: a frozen container's ivar-derived membership is still the caller's to widen" do
        index = { "a" => true }
        values = Class.new(Array) do
          define_method(:initialize) do |*args, idx|
            super(*args)
            @index = idx
          end

          def include?(value) = @index.key?(value)
        end.new(%w[a], index).freeze
        klass = declared_with(values)

        expect(accepts_c?(klass)).to be(false)
        index["c"] = true
        expect(accepts_c?(klass)).to be(true)
      end

      # A membership container that is not an Array reaches this path and is stored as the caller's OBJECT — not
      # copied, and so not refused either: nothing of axn's answers membership, the caller's own object does, so
      # the divergence above is unreachable. What remains is the aliasing the copy exists to prevent, recorded
      # here rather than claimed closed. A `Range` is frozen by construction and so is unaffected.
      it "records the residue: a Set membership container stays the caller's own object" do
        values = Set.new(%w[a])
        klass = declared_with(values)

        expect(klass.internal_field_configs.first.validations.dig(:inclusion, :in)).to be(values)
        expect(accepts_c?(klass)).to be(false)
        values << "c"
        expect(accepts_c?(klass)).to be(true)
      end
    end
  end

  describe "the canonicalization this check shares with the renderer" do
    # The declaration check and the rendering it predicts must agree, so the contract layer calls the
    # renderer's canonicalization rather than re-deriving it. Asserted here so narrowing the renderer's
    # public surface fails loudly rather than silently disarming the guard.
    it "is publicly callable and collapses two encodings of one property" do
      expect(Axn::Internal::Reflection::Values).to respond_to(:canonical_wire_key)
      expect(Axn::Internal::Reflection::Values.canonical_wire_key(latin1_name)).to eq("café")
      expect(Axn::Internal::Reflection::Values.canonical_wire_key(utf8_name)).to eq("café")
    end
  end

  describe "two names that collapse onto one property" do
    it "rejects them on exposes" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on expects" do
      names = [utf8_name, latin1_name]

      expect { build_axn { expects(*names) } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them across separate declarations, not just within one batch" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          expects first
          expects second
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "names both spellings and the fix" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
        expect(error.message).to include(":café", 'caf\xE9', "stay distinct once converted to UTF-8")
      }
    end

    it "rejects two subfield leaf names under one route" do
      leaves = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects :payload, type: Hash
          expects(*leaves, on: :payload)
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "still allows one leaf spelling under two different routes" do
      leaf = utf8_name

      klass = build_axn do
        expects :billing, type: Hash
        expects :shipping, type: Hash
        expects leaf, on: :billing, as: :billing_city, optional: true
        expects leaf, on: :shipping, as: :shipping_city, optional: true
      end

      expect(klass.subfield_configs.size).to eq(2)
    end
  end

  # Identity is the property a name renders as under its RESOLVED wire parent, not under the route as
  # written. A dotted `on:` and a subfield reader (or an `as:` alias of one) are two supported spellings of
  # the same route, so two leaf names that canonicalize to one property can sit under one parent with nothing
  # syntactic in common — and the reflected schema then emits that property twice. Resolution is taken from
  # the SubfieldTree the schema and the runtime already read, so the guard cannot disagree with them.
  describe "two routes that resolve to the same wire parent" do
    it "rejects colliding leaf names reached by a dotted route and a subfield reader" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        project_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :bar, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "foo\.bar\.café"/)
    end

    it "rejects them when the second route is an as: alias of the parent" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        project_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash, as: :aliased
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :aliased, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "foo\.bar\.café"/)
    end

    it "names both offenders with the route each was declared under" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        project_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :bar, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
        # A route is canonicalized to a Symbol at declaration (see `_expects_subfields`), so a dotted route
        # is named as the Symbol it is stored as whichever spelling declared it — the PATH is what tells the
        # two declarations apart, and it is still each one's own.
        expect(error.message).to include(':café (on: :"foo.bar")', 'caf\xE9" (on: :bar)')
      }
    end

    # One wire slot reached by two routes is a MERGED NODE — legitimate, gated on reader-name uniqueness
    # instead, and reflecting as one property. The rule is "canonical paths equal, RAW paths different", so
    # this stays declarable: it is the case where both halves are equal.
    it "still allows one leaf spelling reached by a dotted route and a reader route" do
      klass = build_axn do
        expects :address, type: Hash
        expects :billing, on: :address, type: Hash
        expects :zip, on: "address.billing", as: :zip_a, optional: true
        expects :zip, on: :billing, as: :zip_b, optional: true
      end

      expect(klass.input_schema.dig(:properties, :address, :properties, :billing, :properties).keys).to eq([:zip])
    end

    # Which routes those are is decided by `on:`, and a route is judged as WRITTEN (the root must name a
    # declared reader; the duplicate check keys a config by it) and then SPLIT AGAIN by every consumer —
    # `SubfieldTree`, `resolve_parent`, the ambient checks, the executor's parent memo. So a caller value
    # whose rendering answers differently on successive reads had the guard judging one route while the tree
    # built another: two subfields landed on ONE node, merging as if they were two routes to one wire slot,
    # where the same declaration written honestly is a duplicate. Canonicalized once, at declaration, exactly
    # as a field NAME is — after which every read is a Symbol's own.
    describe "a route that renders differently on each read" do
      # A `String` route whose rendering is "q" first and "p" afterwards. Both conversions flip together, so
      # the fixture does not depend on which one a layer reaches for.
      def flipping_route
        Class.new(String) do
          def to_s
            @reads = (@reads || 0) + 1
            @reads == 1 ? "q" : "p"
          end

          def to_sym = to_s.to_sym
          def reads = @reads || 0
        end.new("ignored")
      end

      it "anchors the subfield where the guard judged it, not where a later read points" do
        route = flipping_route
        klass = build_axn do
          expects :p, type: Hash
          expects :q, type: Hash
          expects :a, on: :p, optional: true
          expects :a, on: route, as: :qa, optional: true
        end

        expect(route.reads).to eq(1)
        expect(klass.subfield_configs.map(&:on)).to eq(%i[p q])
        expect(klass.input_schema[:properties].transform_values { |prop| prop[:properties]&.keys }).to eq({ p: [:a], q: [:a] })
      end

      # And the other direction: when that one read is the colliding one, it is rejected — rather than cleared
      # by the guard on one route and then resolved onto the other.
      it "rejects it as a duplicate when the judged route is the one already declared" do
        route = flipping_route
        route.to_s # spend the "q" answer, so the read the declaration makes is "p"

        expect do
          build_axn do
            expects :p, type: Hash
            expects :a, on: :p, optional: true
            expects :a, on: route, as: :pa, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate field\(s\) declared: a/)
      end

      # A String route is not the defect — the route is stored as the Symbol it names, whichever spelling
      # declared it, so the two spellings are one route by construction rather than by comparison.
      it "stores an ordinary String route as the Symbol it names" do
        klass = build_axn do
          expects :address, type: Hash
          expects :billing, on: "address", type: Hash
          expects :zip, on: "address.billing", optional: true
        end

        expect(klass.subfield_configs.map(&:on)).to eq(%i[address address.billing])
        expect(klass.input_schema.dig(:properties, :address, :properties, :billing, :properties).keys).to eq([:zip])
      end

      # Canonicalizing a route is only worth anything if it cannot be SKIPPED, and the decision of whether a
      # route is present at all was itself a dispatch: `present?`/`blank?` are ActiveSupport methods on Object,
      # so a `String` subclass overrides them. One answering "blank" to that decision and "present" to a later
      # reader was stored raw — the very split canonicalizing exists to close, reachable through the guard
      # protecting it. Absence is now decided from the value's class and Ruby's own `empty?`.
      it "canonicalizes a route whose own blank? calls it absent" do
        route = Class.new(String) do
          def blank?
            @reads = (@reads || 0) + 1
            @reads == 1
          end
        end.new("p")

        klass = build_axn do
          expects :p, type: Hash
          expects :a, on: route, optional: true
        end

        expect(klass.subfield_configs.map(&:on)).to eq([:p])
        expect(klass.input_schema.dig(:properties, :p, :properties).keys).to eq([:a])
      end

      # The complement, so the fix is not just "always symbolize": a genuinely absent route still means "no
      # route", and its field stays top-level rather than becoming a subfield of something. Absent is the
      # whole of what `blank?` meant here — `false` and a whitespace-only String included, in any encoding —
      # because that is what the decision this replaced answered, and narrowing it turned two spellings of
      # "no route" into a NoMethodError from `to_sym` and a whitespace route naming a reader nobody declared.
      it "still treats every blank spelling as no route at all" do
        [nil, false, "", "   ", "\t\n", " ", (+"  ").force_encoding("ASCII-8BIT"), "  ".encode("UTF-16LE"), :""].each do |absent|
          klass = build_axn do
            expects :p, type: Hash
            expects :a, on: absent, optional: true
          end

          expect(klass.subfield_configs).to be_empty
          expect(klass.internal_field_configs.map(&:field)).to eq(%i[p a])
        end
      end

      # A String subclass answering "blank" is still canonicalized when its BYTES name a route — blankness is
      # read off the value's own class and bytes, never off the answer it gives. (The lie is exercised in
      # full above; this pins that the widened blank set did not turn one into an absent route.)
      it "does not treat a lying blank? as an absent route" do
        route = Class.new(String) do
          def blank? = true
          def present? = false
        end.new("p")

        klass = build_axn do
          expects :p, type: Hash
          expects :a, on: route, optional: true
        end

        expect(klass.subfield_configs.map(&:on)).to eq([:p])
      end

      # And the other direction of the same split, which is why absence canonicalizes to `nil` rather than
      # being left as the caller wrote it: a route judged absent here that a `present?` one line down called
      # present took the SUBFIELD path with the raw value, and a blank one anchored nothing —
      # `NoMethodError: undefined method 'to_sym' for nil` out of the route resolution, for a declaration
      # whose only sin was an empty String with an opinion. Every reader below now sees nil-or-Symbol.
      it "treats a blank route as absent even when its own present? claims otherwise" do
        route = Class.new(String) do
          def present? = true
          def blank? = false
        end

        ["", "   "].each do |bytes|
          klass = build_axn do
            expects :p, type: Hash
            expects :a, on: route.new(bytes), optional: true
          end

          expect(klass.subfield_configs).to be_empty
          expect(klass.internal_field_configs.map(&:field)).to eq(%i[p a])
        end
      end

      # Deciding blankness reads the route's bytes, and bytes that are invalid for their own encoding cannot
      # be read — so the decision declines to answer rather than becoming the failure itself. What such a
      # route means is the name rules' verdict to give (they render it), one line further on, exactly as
      # before blankness was decided here at all.
      it "leaves a route whose bytes are invalid for its encoding to the name it converts to" do
        expect do
          build_axn do
            expects :p, type: Hash
            expects :a, on: (+"\xff").force_encoding("UTF-8"), optional: true
          end
        end.to raise_error(EncodingError)
      end

      # Everything that is neither a name nor absent is a programmer error named as one — the absent set is
      # nil/false/empty-or-whitespace String/empty Symbol, not "anything that answers `empty?`", so `[]` is a
      # value that cannot name a route rather than a spelling of "no route". It used to be diagnosed as
      # whatever `to_sym` happened to raise — `NoMethodError: undefined method 'to_sym' for an instance of
      # Array`, naming neither the option nor what was wrong with the value.
      it "raises ArgumentError naming the option and the offending class for a route that is not a name" do
        { [] => "Array", {} => "Hash", 123 => "Integer", true => "TrueClass", Object.new => "Object" }.each do |not_a_name, klass|
          expect do
            build_axn do
              expects :p, type: Hash
              expects :a, on: not_a_name, optional: true
            end
          end.to raise_error(ArgumentError, /\Aon: must be a String or Symbol naming a parent reader \(got a value of class #{klass}\)/)
        end
      end

      # The type is decided and the class named without asking the route anything — an offender whose `is_a?`
      # claims String, or whose `inspect`/`to_s` raises, must not route around the guard or replace the verdict
      # with its own exception (a NotImplementedError is outside StandardError and escapes every rescue above).
      # And it pins the narrowing: a route that merely ANSWERS `to_sym` used to be accepted and canonicalized,
      # anchoring at whatever its `to_sym` invented independently of what it renders as.
      it "reports axn's own ArgumentError rather than the route's exception" do
        hostile = Class.new do
          def is_a?(_klass) = true
          def inspect = raise(NotImplementedError, "inspect should not build the message")
          def to_s = raise(NotImplementedError, "to_s should not build the message")
          def to_sym = :p
        end.new

        expect do
          build_axn do
            expects :p, type: Hash
            expects :a, on: hostile, optional: true
          end
        end.to raise_error(ArgumentError, /\Aon: must be a String or Symbol naming a parent reader/)
      end
    end
  end

  # A `model:` field also claims the `<field>_id` axn generates for it, so an explicit sibling that
  # canonicalizes to the same property collapses onto it in the reflected schema. The generated name comes
  # from the same `Internal::FieldConfig.model_id_key` the schema uses, so the two cannot disagree about it.
  describe "a model:-generated <field>_id" do
    # A PORO with a finder — `spec/` runs without Rails.
    def widget_class
      Class.new do
        def self.name = "Widget"
        def self.find(_id) = new
      end
    end

    it "collides with an explicit _id declared in another encoding" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        project_axn do
          expects utf8, model: widget, optional: true
          expects latin1_id, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "café_id"/)
    end

    it "names it as generated, so the author is not sent looking for a name they never wrote" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        project_axn do
          expects utf8, model: widget, optional: true
          expects latin1_id, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /the `model:`-generated :café_id of :café/)
    end

    it "collides for a subfield model: too" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        project_axn do
          expects :p, type: Hash
          expects utf8, on: :p, model: widget, optional: true
          expects latin1_id, on: :p, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "p\.café_id"/)
    end

    # THE control, and the reason the rule is "canonical equal, raw different" rather than "generated ids
    # join the claimed set". An explicit `<field>_id` in the SAME spelling is a supported pattern: schema
    # reflection merges the two (`properties[id_field] ||= id_prop`) and emits ONE property. Rejecting it
    # would break a legal declaration.
    it "still allows an explicit _id declared in the same spelling, merging into one property" do
      utf8 = utf8_name
      widget = widget_class

      klass = build_axn do
        expects utf8, model: widget, optional: true
        expects :café_id, optional: true
      end

      expect(klass.input_schema[:properties].keys).to eq([:café_id])
    end

    # Two `model:` fields whose generated ids would collide are already rejected on their own names — the
    # generated ids collide only when the names do, since the id is the name plus a fixed suffix. Asserted so
    # the mirror case is on the record as covered rather than unexamined.
    it "is unreachable for two model: fields, whose own names collide first" do
      utf8 = utf8_name
      latin1 = latin1_name
      widget = widget_class

      expect do
        build_axn do
          expects utf8, model: widget, optional: true
          expects latin1, model: widget, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    # Checked mirror that does NOT apply: an outbound `model:` field reflects under its own name and emits no
    # generated `<field>_id` at all, so there is no generated property for an explicit one to collide with.
    it "has no outbound counterpart, since exposes generates no _id property" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      klass = build_axn do
        exposes utf8, model: widget, optional: true
        exposes latin1_id, optional: true
      end

      expect(klass.output_schema[:properties].size).to eq(2)
    end
  end

  # Six mechanisms can contribute a JSON property name at one node, and five rounds of review each surfaced a
  # different PAIR of them that could converge without either seeing the other. They are judged in one claim
  # space now, so the pairs below are the cross-product rather than a list of past defects: each is checked in
  # its encoding-distinct form (rejected) and its same-spelling form (a legal merge, emitting one property).
  # The mechanism list, with the reflection each mirrors, is in the comment on
  # `_reject_colliding_property_claims!`.
  describe "every mechanism that can name a property at one node" do
    def widget
      @widget ||= Class.new do
        def self.name = "Widget"
        def self.find(_id) = new
      end
    end

    # The reflected property names at one node, canonicalized — so "one property" and "two that collapse onto
    # one" are distinguishable, which is the whole question.
    def canonical_props(klass, *path)
      node = path.inject(klass.input_schema) { |acc, key| acc.dig(:properties, key) }
      (node[:properties] || {}).keys.map { |k| Axn::Internal::Reflection::Values.canonical_wire_key(k) }
    end

    describe "a subfield leaf and a shape member of its parent" do
      it "rejects them when their names collapse onto one property" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          project_axn do
            expects(:payload, type: Hash) { field utf8, type: String }
            expects latin1, on: :payload, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names the shape member and the subfield as the two sources" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          project_axn do
            expects(:payload, type: Hash) { field utf8, type: String }
            expects latin1, on: :payload, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
          expect(error.message).to include("shape member :café of :payload", "(on: :payload)")
        }
      end

      it "still merges them into one property when the spelling matches" do
        utf8 = utf8_name

        klass = build_axn do
          expects(:payload, type: Hash) { field utf8, type: String }
          expects utf8, on: :payload, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end

      it "rejects them at depth, where the member is nested and the subfield is dotted" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          project_axn do
            expects(:payload, type: Hash) { field(:mid, type: Hash) { field utf8, type: String } }
            expects latin1, on: "payload.mid", optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.mid\.café"/)
      end
    end

    describe "a shape member and a model:-generated <field>_id" do
      it "rejects them when their names collapse onto one property" do
        utf8_id = :café_id
        latin1 = latin1_name
        model = widget

        expect do
          project_axn do
            expects(:payload, type: Hash) { field utf8_id, type: String }
            expects latin1, on: :payload, model:, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café_id"/)
      end

      it "still merges them when the spelling matches" do
        utf8_id = :café_id
        utf8 = utf8_name
        model = widget

        klass = build_axn do
          expects(:payload, type: Hash) { field utf8_id, type: String }
          expects utf8, on: :payload, model:, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café_id"])
      end
    end

    describe "an implicit intermediate introduced by a dotted on:" do
      it "collides with a shape member of the same parent" do
        utf8 = utf8_name
        route = "payload.#{latin1_name}"

        expect do
          project_axn do
            expects(:payload, type: Hash) { field utf8, type: Hash }
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names itself as a nested key rather than as something the author declared" do
        utf8 = utf8_name
        route = "payload.#{latin1_name}"

        expect do
          project_axn do
            expects(:payload, type: Hash) { field utf8, type: Hash }
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /a nested key introduced by :leaf/)
      end

      it "collides with a subfield declared at the same parent" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          project_axn do
            expects :payload, type: Hash
            expects :leaf, on: "payload.#{utf8}", optional: true
            expects latin1, on: :payload, type: Hash, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "collides with a model:-generated id at the same parent" do
        utf8 = utf8_name
        route = "payload.#{"caf\xE9_id".dup.force_encoding('ISO-8859-1').to_sym}"
        model = widget

        expect do
          project_axn do
            expects :payload, type: Hash
            expects utf8, on: :payload, model:, optional: true
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café_id"/)
      end

      it "collides with another implicit intermediate at the same parent" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          project_axn do
            expects :payload, type: Hash
            expects :a, on: "payload.#{utf8}", optional: true
            expects :b, on: "payload.#{latin1}", optional: true
          end
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "still merges with a subfield of the same spelling" do
        utf8 = utf8_name

        klass = build_axn do
          expects :payload, type: Hash
          expects :leaf, on: "payload.#{utf8}", optional: true
          expects utf8, on: :payload, type: Hash, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end
    end

    # A `Data`-typed field declaring a shape block emits its type's own members as properties beside the
    # shape's (Internal::Reflection::Schema#apply_structured_schema!), so those two sets share a node. This mechanism was
    # not on the review's list; it was found by walking the cross-product.
    describe "the members of a Data type declared alongside a shape" do
      it "rejects a shape member that collapses onto a Data member's property" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          project_axn { expects(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names the Data type as the source" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          project_axn { expects(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /a member of the .* type declared on :payload/)
      end

      # Naming the type runs a bound `Module#to_s`: a class can define its own, and one that raises would
      # replace the collision being reported — a ScriptError there escapes class definition entirely.
      it "reports the collision even when the type's own to_s raises" do
        shaped = Data.define(:café) do
          def self.to_s = raise(NotImplementedError, "hijacked from Class#to_s")
        end
        latin1 = latin1_name

        expect { project_axn { expects(:payload, type: shaped) { field latin1, type: String } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      # Naming the type is also writing foreign BYTES into the message: a constant may hold non-UTF-8 ones
      # (`const_set` accepts them, and a Latin-1-encoded source file declares them), so the collision report
      # raised Encoding::CompatibilityError from its own interpolation instead of naming the property.
      it "reports the collision when the type's own constant holds non-UTF-8 bytes" do
        exotic = "Caf\xE9Type".dup.force_encoding("ISO-8859-1").to_sym
        shaped = Data.define(:café)
        Object.const_set(exotic, shaped)
        latin1 = latin1_name

        expect { project_axn { expects(:payload, type: shaped) { field latin1, type: String } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
            expect(error.message).to include("a member of the CaféType type declared on :payload")
            expect(error.message.encoding).to eq(Encoding::UTF_8)
            expect(error.message).to be_valid_encoding
          }
      ensure
        Object.send(:remove_const, exotic) if exotic && Object.const_defined?(exotic)
      end

      it "still merges a shape member of the same spelling" do
        shaped = Data.define(:café)
        utf8 = utf8_name

        klass = build_axn { expects(:payload, type: shaped) { field utf8, type: String } }

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end
    end

    # Mechanism 6's claims must match what `Schema#apply_structured_schema!` actually emits, in both
    # directions. The guard reads that decision from `Schema.shape_property_plan` rather than restating it:
    # restating it both missed a path the schema takes (`of:` element types seed `items[:properties]`) and
    # ignored a gate the schema honors (an output value that is not provably member-keyed), so it
    # simultaneously let a collapse through and rejected a legal declaration.
    describe "a structured type whose properties the schema does not emit" do
      # A custom `as_json`/`to_h` is what `serialize_value` would follow, so the serialized form is not
      # provably member-keyed and the OUTPUT property is left untyped — there is no property for a shape
      # member to collide with, and rejecting would break a declaration the author is entitled to write.
      it "does not reject an exposed Data type carrying a custom as_json" do
        custom = Data.define(:café) do
          def as_json(*) = { "totally" => "different" }
        end
        latin1 = latin1_name

        expect { build_axn { exposes(:thing, type: custom) { field latin1, type: String } } }.not_to raise_error
      end

      it "does not reject an exposed Data type carrying a custom to_h" do
        custom = Data.define(:café) do
          def to_h = { totally: "different" }
        end
        latin1 = latin1_name

        expect { build_axn { exposes(:thing, type: custom) { field latin1, type: String } } }.not_to raise_error
      end

      it "still rejects an exposed plain Data type, whose properties ARE emitted" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect { project_axn { exposes(:thing, type: shaped) { field latin1, type: String } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "thing\.café"/)
      end

      # INPUT reflects the shape a client is expected to send, regardless of how the value serializes, so a
      # custom as_json/to_h changes nothing inbound and the collision is real there. Both spellings, because the
      # outbound carve-out has two of them and an inbound one that read only `as_json` would be a hole under the
      # other.
      it "still rejects inbound, where serialization does not decide the schema" do
        custom = Data.define(:café) do
          def as_json(*) = { "totally" => "different" }
        end
        latin1 = latin1_name

        expect { project_axn { expects(:thing, type: custom) { field latin1, type: String } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "thing\.café"/)
      end

      it "still rejects a custom to_h inbound too" do
        custom = Data.define(:café) do
          def to_h = { totally: "different" }
        end
        latin1 = latin1_name

        expect { project_axn { expects(:thing, type: custom) { field latin1, type: String } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "thing\.café"/)
      end

      # A scalar `of:` reads members off the element (`String#length`), which stays a string — the members are
      # validated but never become properties, so two of them cannot collapse.
      it "does not reject colliding member names under a scalar of:" do
        members = [Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                   Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {})]

        expect { build_axn { expects :list, type: Array, of: String, shape: { members:, container: Array } } }
          .not_to raise_error
      end
    end

    # An `of:` element type seeds the ARRAY ELEMENT's properties, which the shape's members then merge over —
    # a separate node from the field's own, and one the guard reached only once it started asking the schema
    # where properties land. (This also corrects the earlier claim that `of:` contributes nothing: its ELEMENT
    # TYPE does contribute property names, at the element node.)
    describe "an of: element type's members, inside the array's items" do
      def element_props(klass)
        klass.input_schema.dig(:properties, :list, :items, :properties).keys.map { |k| Axn::Internal::Reflection::Values.canonical_wire_key(k) }
      end

      it "rejects a shape member that collapses onto an element type's property" do
        shaped = Data.define(:café)
        members = [Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: { type: String })]

        expect { project_axn { expects :list, type: Array, of: shaped, shape: { members:, container: Array } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "list\.\[\]\.café"/)
      end

      it "still merges an element type's property with a shape member of the same spelling" do
        shaped = Data.define(:café)
        members = [Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: { type: String })]

        klass = build_axn { expects :list, type: Array, of: shaped, shape: { members:, container: Array } }

        expect(element_props(klass)).to eq(["café"])
      end

      # Each array's element node is its own namespace, under that field's path — so the same element property
      # name under two different arrays is two properties, not a collision. (A subfield of an array-typed field
      # is rejected upstream for an unrelated reason, so an element property can never meet one.)
      it "keeps each array's element properties in their own namespace" do
        shaped = Data.define(:café)
        latin1_members = [Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: { type: String })]

        klass = build_axn do
          expects :list, type: Array, of: shaped, optional: true
          expects :other, type: Array, shape: { members: latin1_members, container: Array }, optional: true
        end

        other_props = klass.input_schema.dig(:properties, :other, :items, :properties).keys
                           .map { |k| Axn::Internal::Reflection::Values.canonical_wire_key(k) }

        expect(element_props(klass)).to eq(["café"])
        expect(other_props).to eq(["café"])
      end
    end

    describe "the outbound claim space" do
      it "rejects a Data member colliding with an exposed shape member" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          project_axn { exposes(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      # Inbound and outbound are separate spaces: one name may legitimately be both expected and exposed, and
      # they are emitted into different schemas.
      it "does not compare an inbound name against an outbound one" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects utf8, optional: true
            exposes latin1, optional: true
          end
        end.not_to raise_error
      end
    end
  end

  describe "a name with no UTF-8 rendering" do
    it "is rejected on expects" do
      name = unrenderable_name

      expect { project_axn { expects name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected on exposes" do
      name = unrenderable_name

      expect { build_axn { exposes name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected before the collision check, so two of them do not report a shared property" do
      names = [unrenderable_name, "worse\xFE".dup.force_encoding("ASCII-8BIT").to_sym]

      expect { project_axn { expects(*names) } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "names the offending bytes escaped to ASCII and the fix" do
      name = unrenderable_name

      expect { project_axn { expects name } }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include('bad\xFF', "Declare it under a UTF-8 name")
      }
    end
  end

  # A dotted `on:` segment becomes a JSON property name in the reflected schema — the root names a declared
  # field, each deeper segment is an implicit nested key — so it carries the same UTF-8 promise a declared name
  # does, enforced by the same check. The property-claim collector cannot stand in for this: an unrenderable
  # segment canonicalizes to nothing, so there is no property to compare and the claim is dropped while the
  # schema still emits the segment.
  describe "a dotted on: route segment with no UTF-8 rendering" do
    it "is rejected at declaration rather than reaching JSON.generate" do
      route = "payload.#{unrenderable_name}"

      expect do
        project_axn do
          expects :payload, type: Hash
          expects :leaf, on: route, optional: true
        end
      end.to raise_error(ArgumentError, /a nested key in `on:` becomes a JSON property name/)
    end

    it "names the offending segment escaped to ASCII and the fix" do
      route = "payload.#{unrenderable_name}"

      expect do
        project_axn do
          expects :payload, type: Hash
          expects :leaf, on: route, optional: true
        end
      end.to raise_error(ArgumentError) { |error|
        expect(error.message).to include('bad\xFF', "Declare it under a UTF-8 name")
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
      }
    end

    # In the ROOT position the accurate diagnosis is a different one: a root must name an already-declared
    # reader, and nothing is declared under an unrenderable name, so "no such reader exists" is what the author
    # needs to hear. What matters is that the message can be BUILT — it interpolates `on:`, and raw non-UTF-8
    # bytes there raised Encoding::CompatibilityError from the reporting itself, surfacing an encoding failure
    # instead of any defect at all.
    it "reports a missing reader, not an encoding failure, in the root position" do
      root = unrenderable_name

      expect { build_axn { expects :leaf, on: root, optional: true } }
        .to raise_error(ArgumentError) { |error|
          expect(error.message).to include("no such reader exists")
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
    end

    it "leaves a valid non-ASCII segment alone, emitting it as a property" do
      route = "payload.#{utf8_name}"

      klass = build_axn do
        expects :payload, type: Hash
        expects :leaf, on: route, optional: true
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys
                  .map { |k| Axn::Internal::Reflection::Values.canonical_wire_key(k) }).to eq(["café"])
    end

    it "leaves a plain ASCII dotted route alone" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :leaf, on: "payload.mid", optional: true
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq([:mid])
    end
  end

  # A structured type's own members become property names beside a shape's, so an unrenderable one is the same
  # defect a field name or a shape member name already carries — one rule, now on every surface that can name a
  # property.
  describe "a structured type member name with no UTF-8 rendering" do
    it "is rejected at declaration rather than reaching JSON.generate" do
      shaped = Data.define(unrenderable_name, :ok)

      expect { project_axn { expects(:t, type: shaped, optional: true) { field :ok, type: String } } }
        .to raise_error(ArgumentError, /a member of a declared type becomes a JSON property name/)
    end

    it "is rejected on exposes too" do
      shaped = Data.define(unrenderable_name, :ok)

      expect { project_axn { exposes(:t, type: shaped, optional: true) { field :ok, type: String } } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    # Derivation is only as good as the plan's fidelity to WHETHER properties are emitted. A `Data` used purely
    # as a `type:` — no shape, no `of:` — contributes no object properties at all, so its member names name
    # nothing and the rule must not fire on it.
    it "does not fire for a Data used only as type:, which emits no member properties" do
      shaped = Data.define(unrenderable_name)

      expect { build_axn { expects :payload, type: shaped, optional: true } }.not_to raise_error
    end

    it "still fires for the same Data once a shape overlays it" do
      shaped = Data.define(unrenderable_name)

      expect { project_axn { expects(:payload, type: shaped, optional: true) { field :ok, type: String } } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "leaves a renderable non-ASCII member name alone" do
      shaped = Data.define(utf8_name)

      klass = build_axn { expects(:t, type: shaped, optional: true) { field :other, type: String } }

      expect(klass.input_schema.dig(:properties, :t, :properties).keys
                  .map { |k| Axn::Internal::Reflection::Values.canonical_wire_key(k) }).to contain_exactly("café", "other")
    end
  end

  # A shape's `container:` is what the shaped value is type-checked against, so it has to be a class. A raw
  # `shape:` may name its own, and a junk one previously reached that check and made every call raise a bare
  # TypeError with nothing pointing at the declaration.
  describe "a non-class shape container:" do
    it "is rejected at declaration rather than failing every call" do
      members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

      expect { build_axn { expects :p, type: Hash, shape: { members:, container: :junk } } }
        .to raise_error(ArgumentError, /a shape's `container:` must be a class \(got :junk\)/)
    end

    it "names the fix" do
      members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

      expect { build_axn { expects :p, type: Hash, shape: { members:, container: 42 } } }
        .to raise_error(ArgumentError, /Name the container class .*or omit `container:`/)
    end

    it "accepts a module as well as a class" do
      members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

      expect { build_axn { expects :p, type: Hash, shape: { members:, container: Enumerable } } }.not_to raise_error
    end

    it "leaves a valid container: validating as before" do
      members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { presence: true })]
      klass = build_axn { expects :p, type: Hash, shape: { members:, container: Hash } }

      expect(klass.call(p: { a: 1 })).to be_ok
      expect(klass.call(p: {})).not_to be_ok
    end
  end

  # Derivation is only as good as the walker's coverage of WHERE properties are emitted. A multi-class `type:`
  # or `of:` reflects as alternative branches, each carrying its own `properties` — a namespace the walk has to
  # visit. Branches are alternatives, so one name in two different branches describes one property two ways and
  # is not a collision.
  describe "properties emitted inside anyOf branches" do
    it "rejects a collision inside a branch" do
      colliding = Data.define(utf8_name, latin1_name)
      other = Data.define(:other)

      expect { project_axn { expects :l, type: Array, of: [colliding, other], optional: true } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both resolve to the JSON property .*café/)
    end

    it "still declares the same name in two different branches" do
      first = Data.define(:shared)
      second = Data.define(:shared)

      expect { build_axn { expects :l, type: Array, of: [first, second], optional: true } }.not_to raise_error
    end

    # Where the branches come from, checked rather than assumed: only an `of:` element type reflects as a
    # property-bearing branch (`single_items_schema`). A multi-class `type:` maps each class through
    # `single_type_for`, which gives a Data `"string"` — no properties, so no namespace. The walk handles
    # `anyOf` wherever it appears regardless, since which sites produce one is the emitter's business to change.
    it "emits no property-bearing branch for a multi-class type:, so there is nothing to collide" do
      colliding = Data.define(utf8_name, latin1_name)
      members = [Axn::Core::Contract::ShapeConfig.new(field: :ok, validations: {})]
      klass = nil

      expect { klass = build_axn { expects :t, type: [colliding, Hash], shape: { members:, container: Hash }, optional: true } }
        .not_to raise_error
      expect(klass.input_schema.dig(:properties, :t, :anyOf).flat_map(&:keys)).not_to include(:properties)
    end
  end

  # Derivation is only as good as the seam's agreement on WHICH members exist. The declaration guard and the
  # runtime validator capture a member list with `each`; reflection used `Array(...)` and then dispatched
  # `filter_map`, which an Array subclass can answer differently — so the three walks saw two different answers.
  # The fix is in the EMITTER, and it corrects the guard at the same time, because the guard is derived from it.
  describe "a caller-supplied member list that answers filter_map differently from each" do
    # Overrides every Enumerable convenience a consumer might reach for, leaving only `each` honest — so any
    # consumer not going through the shared seam shows up.
    def hiding_member_list(*members)
      Class.new(Array) do
        def filter_map(*) = []
        def map(*) = []
        def select(*) = []
        def flat_map(*) = []
        def any?(*) = false
        def to_a = []
      end.new(members)
    end

    it "is walked identically by reflection, the guard, and runtime validation" do
      members = hiding_member_list(Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {}),
                                   Axn::Core::Contract::ShapeConfig.new(field: :b, validations: {}))
      klass = build_axn { expects :p, type: Hash, shape: { members:, container: Hash } }
      stored = klass.internal_field_configs.first.validations[:shape][:members]

      expect(klass.input_schema.dig(:properties, :p, :properties).keys).to eq(%i[a b])
      expect(Axn::Internal::ShapeGraph.capture(stored).size).to eq(2)
      expect(stored.each_with_object([]) { |m, acc| acc << m }.size).to eq(2)
    end

    # The same divergence in the redaction path is a LEAK rather than a disagreement: a `sensitive:` member the
    # walk cannot see contributes no key to the ParameterFilter, so its value is logged in the clear.
    it "still redacts a sensitive: member the list hides from flat_map" do
      members = hiding_member_list(Axn::Core::Contract::ShapeConfig.new(field: :secret, validations: {}, sensitive: true))
      klass = build_axn { expects :p, type: Hash, shape: { members:, container: Hash } }

      sliced = klass._context_slice(data: { p: { secret: "SHH" } }, direction: :inbound)

      expect(sliced.dig(:p, :secret)).to eq("[FILTERED]")
    end

    it "does not let such a list hide a collision from the guard" do
      members = hiding_member_list(Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                                   Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}))

      expect { project_axn { expects :p, type: Hash, shape: { members:, container: Hash } } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /café/)
    end
  end

  describe "the identical-name duplicate this generalizes" do
    it "keeps its existing message" do
      expect do
        build_axn do
          expects :foo, type: String
          expects :foo, numericality: { greater_than: 10 }
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, "Duplicate field(s) declared: foo")
    end

    it "names every offending occurrence, not just the first" do
      expect { build_axn { expects :foo, :foo, :foo } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, "Duplicate field(s) declared: foo, foo")
    end

    # The message names each offender by its canonical property. Naming it by the Symbol would concatenate a
    # non-UTF-8 name into UTF-8 prose, and the Encoding::CompatibilityError from building the message would
    # reach the caller in place of the duplicate error it was trying to report.
    it "reports a non-UTF-8-encoded name as a duplicate rather than an encoding failure" do
      name = latin1_name

      expect do
        build_axn do
          expects name
          expects name
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
        expect(error.message).to include("café")
      }
    end

    it "reports a batch mixing encodings without the join failing" do
      names = [latin1_name, latin1_name, :naïve, :naïve]

      expect { build_axn { expects(*names) } }.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
        expect(error.message).to eq("Duplicate field(s) declared: café, naïve")
      }
    end
  end

  describe "shape member names" do
    it "rejects two members that collapse onto one property" do
      first = utf8_name
      second = latin1_name

      expect do
        project_axn do
          expects :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects a duplicate member name, which previously kept only the last in the schema" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field :a, type: Integer
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate shape member declared: :a\b/)
    end

    # A member name is normalized to a Symbol at declaration, exactly as a top-level field name is, so these
    # two are not merely one property — they are one NAME, and the identical-duplicate message is the accurate
    # one. That also puts shape members in step with `expects :foo, "foo"`, which has always reported
    # "Duplicate field(s) declared: foo" rather than a collapse.
    it "treats a symbol and a string spelling of one member name as one name" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field "a", type: Integer
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate shape member declared: :a —/)
    end

    it "rejects a member name with no UTF-8 rendering" do
      name = unrenderable_name

      expect do
        project_axn do
          expects :payload, type: Hash do
            field name, type: String
          end
        end
      end.to raise_error(ArgumentError, /a shape member name becomes a JSON property name/)
    end

    it "reports a collision in valid UTF-8 even when one spelling is not" do
      first = utf8_name
      second = latin1_name

      expect do
        project_axn do
          expects :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
      }
    end

    # A member's own options are rejected inside the builder, which runs BEFORE the name guard can see the
    # resolved members — so every message that names a member has to survive a name with no UTF-8 rendering,
    # or the option check reports an Encoding::CompatibilityError from building its own message and the
    # naming defect never surfaces. Each combination below reaches a different one of those messages.
    describe "a member name with no UTF-8 rendering, combined with a member option" do
      it "still raises the declaration error when the member declares model:" do
        name = unrenderable_name

        expect do
          build_axn do
            expects :payload, type: Hash do
              field name, model: true
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      it "still raises the declaration error when an exposes member declares user_facing:" do
        name = unrenderable_name

        expect do
          build_axn do
            exposes :payload, type: Hash do
              field name, type: String, user_facing: true
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      it "still raises the declaration error when the member declares as:" do
        name = unrenderable_name

        expect do
          build_axn do
            expects :payload, type: Hash do
              field name, type: String, as: :renamed
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      # A member carrying BOTH an unusable name and a rejected option now reports the option. The naming rule
      # moved onto the emitted-property walk — it has to, since a name the schema never emits names nothing and
      # rejecting it is an over-rejection — and that walk runs after the option checks. Both are real defects;
      # what matters is that the option message survives an unrenderable name rather than raising
      # Encoding::CompatibilityError while building itself.
      it "reports the option for a raw shape: member that also declares user_facing:, in valid UTF-8" do
        member = Axn::Core::Contract::ShapeConfig.new(field: unrenderable_name, validations: {}, user_facing: true)

        expect { build_axn { exposes :payload, type: Hash, shape: { members: [member] } } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("does not support user_facing:")
            expect(error.message.encoding).to eq(Encoding::UTF_8)
            expect(error.message).to satisfy(&:valid_encoding?)
          }
      end

      it "still raises the declaration error when the member carries no options at all" do
        name = unrenderable_name

        expect do
          project_axn do
            expects :payload, type: Hash do
              field name
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end
    end

    it "reaches members nested inside a member's own block" do
      first = utf8_name
      second = latin1_name

      expect do
        project_axn do
          expects :payload, type: Hash do
            field :inner, type: Hash do
              field first, type: String
              field second, type: Integer
            end
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "reaches members supplied as a raw shape: kwarg, which never route through the builder" do
      members = [
        Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
        Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}),
      ]

      expect { project_axn { expects :payload, type: Hash, shape: { members: } } }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on an exposes shape too" do
      first = utf8_name
      second = latin1_name

      expect do
        project_axn do
          exposes :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "leaves distinct member names alone" do
      klass = build_axn do
        expects :payload, type: Hash do
          field :a, type: String
          field :b, type: Integer
        end
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq(%i[a b])
    end

    # A raw `shape:` kwarg accepts arbitrary objects as the shape Hash and as its members, while this guard
    # and the schema reflection that emits those members are two separate walks. So an object that lies —
    # about its own type, about which readers it has, or about whether two names are equal — must not be able
    # to make the guard skip a member the schema still emits, or to replace this error with one of its own.
    # Every question below is therefore answered from the real class and the real method table.
    describe "a shape supplied raw, by objects that lie about themselves" do
      # A Hash subclass denying that it is a Hash. `is_a?` is overridable, so a type test that dispatches it
      # skips the whole member walk — while reflection consumes the shape regardless and emits the property
      # twice, which is the exact defect this check exists to prevent.
      def sneaky_hash_class
        Class.new(Hash) do
          def is_a?(klass) = klass == Hash ? false : super
        end
      end

      # A member denying the `field` reader it defines. Membership decided by `respond_to?` would skip it,
      # while the schema reads `member.field` and emits the name anyway.
      def lying_member_class
        Class.new(Axn::Core::Contract::ShapeConfig) do
          # Mirrors Object#respond_to?'s real signature, which takes a positional include_all.
          def respond_to?(name, include_all = false) = name == :field ? false : super # rubocop:disable Style/OptionalBooleanParameter
        end
      end

      # A member served entirely by `method_missing`, which a method-table lookup reports ABSENT by design —
      # `method_missing` is the object's own code, never a definition the table holds. So the member looks
      # reader-less to the first of the two lookups behind `ShapeGraph.fetch`, while its dispatch fallback (and
      # the schema's own plain `member.field`) reaches `method_missing` and emits the name.
      def ghost_member_class
        Class.new do
          def initialize(name) = @name = name

          def method_missing(reader, *_args) # rubocop:disable Style/MissingRespondToMissing
            case reader
            when :field then @name
            when :validations, :metadata then {}
            end
          end
        end
      end

      # A member whose `respond_to_missing?` raises, carrying only the two readers a minimal member needs. Ruby
      # consults that hook whenever a name looked up on a VALUE is ABSENT, and the walk asks every member for the
      # OPTIONAL attributes too (`user_facing:`, `sensitive:`, `method_call:`, `description:`, `metadata:`) —
      # absence is the ordinary case for those, not a corner. So a lookup put to the member runs its code before
      # answering, and this hook raises outside StandardError, so it escapes `expects` in place of any verdict.
      #
      # Deliberately NOT a ShapeConfig subclass: that defines every reader the walk asks for, so no name would be
      # absent and the hook would never be reached at all.
      def raising_lookup_member_class
        unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
        Struct.new(:field, :validations) do
          define_method(:respond_to_missing?) { |*| raise(unswallowable, "respond_to_missing? must not decide this") }
        end
      end

      it "reads a member whose respond_to_missing? raises, without consulting it" do
        members = [raising_lookup_member_class.new(:status, { presence: true })]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }.not_to raise_error
      end

      it "checks a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [
          Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
          Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}),
        ]
        shape[:container] = Hash

        expect { project_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      # The same lie against the sibling guard on the same walk: `user_facing:` on an outbound member is
      # rejected from the resolved members, so a shape that denies being a Hash must not skip that either.
      it "still rejects a user_facing: member inside a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :status, validations: {}, user_facing: true)]
        shape[:container] = Hash

        expect { build_axn { exposes :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /`status` does not support user_facing: on exposes/)
      end

      it "checks a member that denies the field reader it defines" do
        member_class = lying_member_class
        members = [
          member_class.new(field: utf8_name, validations: {}),
          member_class.new(field: latin1_name, validations: {}),
        ]

        expect { project_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      # A member with genuinely no `field` is rejected, not skipped. The documented member contract is `#field`
      # plus `#validations`, and runtime validation reads `member.field` for every member — so skipping it in the
      # guard left a contract that declared, reflected the member as nothing, and then raised NoMethodError on
      # the first call. What the guard's tolerance is for is the other direction: a member that DEFINES the
      # reader cannot escape the check by denying it (the example above).
      it "rejects a member that defines no field reader" do
        members = [Object.new, Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /a shape member must answer to `field`.*of class Object/m)
      end

      # The other half of the documented contract, and the same failure mode: runtime validation reads
      # `member.validations` for every member, dispatched directly, so a member answering to `field` only
      # declared cleanly and then raised NoMethodError on the first call.
      it "rejects a member that answers to field but not validations" do
        members = [Class.new { def field = :a }.new]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /must answer to `validations` as well as `field`.*member `a`/m)
      end

      # The other half of the same contract: a member implementing BOTH readers and nothing else is legal, and
      # works end to end — declaring, projecting, and validating a call.
      it "accepts a member implementing only field and validations, end to end" do
        member = Class.new do
          def field = :a
          def validations = { type: { klass: String } }
        end.new
        klass = build_axn do
          expects :payload, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end

        expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({ a: { type: "string" } })
        expect(klass.call(payload: { a: "ok" })).to be_ok
        expect(klass.call(payload: { a: 1 })).not_to be_ok
      end

      # A member whose name is a String subclass with a hostile `==`. Choosing between the two duplicate
      # messages by comparing the names dispatches that `==`, which raises in place of the declaration
      # error being reported — here a NotImplementedError, outside StandardError, so it escapes every
      # rescue in the framework rather than surfacing as the duplicate it is.
      def hostile_equality_name_class
        Class.new(String) do
          def ==(_other) = raise(NotImplementedError, "hijacked from ==")
        end
      end

      # A ShapeConfig normalizes its name to a Symbol at construction, so a String subclass with a hostile
      # `==` cannot even be STORED as a member name — the hazard is gone at its root rather than guarded
      # against, and the pair reports as the plain duplicate it now is.
      it "cannot store a hostile-== name on a ShapeConfig at all, and reports the duplicate" do
        hostile = hostile_equality_name_class
        members = [
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
        ]

        expect(members.map { |m| m.field.class }).to eq([Symbol, Symbol])
        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate shape member declared: :dup —/)
      end

      # A duck-typed member's reader is not ours to normalize, so this is the one route by which a
      # caller-supplied String name still reaches the spelling comparison — and where deciding "same spelling"
      # must still not dispatch the name's own `==`. It is what keeps that guard exercised.
      it "reports the duplicate for a duck-typed member whose name's own == raises" do
        hostile = hostile_equality_name_class
        members = [duck_typed_member(hostile.new("dup")), duck_typed_member(hostile.new("dup"))]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /Duplicate shape member declared: "dup" —/)
      end

      # A shape graph reachable from inside itself has no traversal at all: the walk recurses until the
      # stack overflows, and SystemStackError is outside StandardError, so it escapes every rescue rather
      # than settling into a reported failure. Rejected at declaration, naming the member that closes it.
      it "rejects a self-referential shape graph instead of overflowing the stack" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
        member.validations[:shape] = { members: [member], container: Hash }
        members = [member]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("a `shape:` graph cannot contain itself", "shape member `a`",
                                             "recurse until the stack overflows", "Give the nested shape its own members")
          }
      end

      it "rejects a self-referential shape graph on exposes too" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
        member.validations[:shape] = { members: [member], container: Hash }
        members = [member]

        expect { build_axn { exposes :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /a `shape:` graph cannot contain itself/)
      end

      it "checks a member whose field reader exists only through method_missing" do
        member_class = ghost_member_class
        members = [member_class.new(utf8_name), member_class.new(latin1_name)]

        expect { project_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      it "still rejects a user_facing: member whose readers exist only through method_missing" do
        member = Class.new do
          # Served entirely by `method_missing`, which a method-table lookup reports absent — so the dispatch
          # fallback is what reads these readers, exactly as the schema's own dispatch does.
          def method_missing(reader, *_args) # rubocop:disable Style/MissingRespondToMissing
            case reader
            when :field then :status
            when :user_facing then true
            when :validations, :metadata then {}
            end
          end
        end.new
        members = [member]

        expect { build_axn { exposes :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /`status` does not support user_facing: on exposes/)
      end

      # A reader whose own body raises NoMethodError for a DIFFERENT name is a bug inside the member, not an
      # absent reader — it must propagate rather than be read as "this member has no name".
      it "propagates a NoMethodError raised inside a member's own field reader" do
        members = [Class.new { def field = nil.no_such_method }.new]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(NoMethodError, /no_such_method/)
      end

      # A shape object that builds a FRESH nested shape on every read never repeats an object, so no
      # identity-based cycle guard can see it — it is endless rather than cyclic, and would otherwise
      # recurse to SystemStackError (outside StandardError) while the class was being defined.
      it "rejects a shape graph that generates a fresh nested shape on every read" do
        generative = Class.new(Hash) do
          def [](key)
            return [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: self.class.new })] if key == :members
            return Hash if key == :container

            super
          end
        end
        shape = generative.new

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("nested more than 64 levels deep", "generated rather than declared",
                                             "builds a fresh nested shape on every read")
          }
      end

      # `:container` is derived from `type:` for a raw shape that omits it, so a raw shape validates the way
      # a block-built one does. Skipping that derivation leaves a nil container reaching ShapeValidator,
      # which raises a bare `TypeError: class or module required` on EVERY call — a runtime crash in place of
      # the declaration-time answer. Neither the shape's `is_a?` nor its `key?` gets to decide.
      it "derives the container for a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
        expect(klass.call(payload: { a: 1 })).to be_ok
      end

      it "derives the container for a shape Hash whose key? claims it already has one" do
        shape = Class.new(Hash) do
          def key?(name) = name == :container ? true : super
        end.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
        expect(klass.call(payload: { a: 1 })).to be_ok
      end

      # The derived shape is a plain Hash assembled from the original's entries, not whatever the original's
      # `merge` chose to return — which can be any object at all, including one carrying no container.
      it "does not take the derived shape from the shape's own merge" do
        shape = Class.new(Hash) do
          def merge(*) = "not a hash at all"
        end.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }
        derived = klass.internal_field_configs.first.validations[:shape]

        expect(derived).to be_instance_of(Hash)
        expect(derived[:container]).to eq(Hash)
        expect(derived[:members].size).to eq(1)
      end

      # An unusable container spelled out explicitly is the same unusable state as an omitted one, so it is
      # derived too rather than carried through to a per-call TypeError.
      it "derives the container for an explicit container: nil" do
        members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: { members:, container: nil } }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
      end

      # Derivation still reports the declaration error it exists to produce when there is no structured
      # `type:` to derive from — the lie must not turn that into silence either.
      it "raises the declaration error when a lying shape Hash has no structured type: to derive from" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        expect { build_axn { expects :payload, shape: } }
          .to raise_error(ArgumentError, /a shape block requires a single structured type:/)
      end

      # A shape reached twice as SIBLINGS is a diamond, not a cycle — the same object legitimately reused as
      # two members' nested shape. Guarding on the ancestor chain (not on "seen anywhere") is what keeps it
      # declarable.
      it "still allows one nested shape object reused by two sibling members" do
        nested = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }
        members = [
          Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: nested }),
          Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: nested }),
        ]

        klass = build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } }

        expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq(%i[a b])
        expect(klass.input_schema.dig(:properties, :payload, :properties, :a, :properties).keys).to eq([:leaf])
      end

      # `[]` is the read every guard AND reflection makes, so a lie there must hide the members from BOTH —
      # that is what "a lie changes what both decide" means. The failure to prevent is the opposite: members
      # reaching reflection that no guard walked, which is what copying the shape's raw entries would do.
      describe "a shape whose [] hides the members its real entries carry" do
        def hidden_member_shape(*members)
          shape = Class.new(Hash) do
            def [](key)
              return [] if key == :members
              return nil if key == :container

              super
            end
          end.new
          shape.store(:members, members)
          shape
        end

        it "does not promote a colliding pair into the reflected schema" do
          shape = hidden_member_shape(Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                                      Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}))

          klass = build_axn { expects :payload, type: Hash, shape: }

          expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({})
        end

        it "does not promote a user_facing: member the outbound guard never saw" do
          shape = hidden_member_shape(Axn::Core::Contract::ShapeConfig.new(field: :status, validations: {}, user_facing: true))

          klass = build_axn { exposes :payload, type: Hash, shape: }

          expect(klass.external_field_configs.first.validations.dig(:shape, :members)).to eq([])
        end

        # The worst of the three: a cyclic member the guard never walked reaches reflection, whose own walk
        # has no cycle guard, and the stack overflows outside StandardError — during schema reflection rather
        # than at declaration.
        it "does not promote a cyclic member into a graph reflection then walks" do
          member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
          member.validations[:shape] = { members: [member], container: Hash }
          shape = hidden_member_shape(member)

          klass = build_axn { expects :payload, type: Hash, shape: }

          expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({})
        end
      end

      # `nil?` is overridable, so every "is this absent?" test on a caller value asks `nil` instead.
      it "does not let a members list claiming to be nil hide itself from the walk" do
        members = Class.new(Array) { def nil? = true }.new
        members.push(Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                     Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}))

        expect { project_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      # `nil?` is a type test, so nothing the container defines gets to decide whether derivation runs — and the
      # container is now itself required to be a class, so the declaration reports that rather than either
      # being hijacked or carrying a junk container through to a per-call TypeError.
      it "reports a container whose nil? raises as the declaration defect it is" do
        raising_nil = Class.new { def nil? = raise(NotImplementedError, "hijacked from nil?") }
        shape = Class.new(Hash) do
          define_method(:[]) { |key| key == :container ? raising_nil.new : super(key) }
        end.new
        shape.store(:members, [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})])

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /`container:` must be a class/)
      end

      # A NoMethodError subclass whose `name` is an object with a raising `==`. Deciding "does this mean no
      # such reader?" must not dispatch that `==`: the NotImplementedError it raises is a ScriptError, which
      # escapes every rescue in the framework, in place of the member's own NoMethodError.
      it "does not dispatch == on a hostile NoMethodError#name" do
        hostile_name = Class.new { def ==(_other) = raise(NotImplementedError, "hijacked from ==") }
        evil_error = Class.new(NoMethodError) { define_method(:name) { hostile_name.new } }
        members = [Class.new do
          def initialize(error_class) = @error_class = error_class

          # Every reader is `method_missing`-backed, which the method table declares nothing for, so the dispatch
          # fallback is the path reached.
          def method_missing(_reader, *_args) = raise(@error_class, "boom") # rubocop:disable Style/MissingRespondToMissing
        end.new(evil_error)]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(NoMethodError, "boom")
      end

      # Every message naming a member is built from a name the walk already read on the way down. Reading it
      # again once a failure is being reported is the same hazard as `inspect`: this member answers the first
      # read and raises on the second, so a re-read replaces the declaration error with its exception.
      it "reports a cycle without re-reading the member's name" do
        member = Class.new do
          def initialize
            @reads = 0
          end

          def field
            @reads += 1
            raise(NotImplementedError, "hijacked from a second read") if @reads > 1

            :a
          end

          def validations = @validations ||= {}
        end.new
        shape = { members: [member], container: Hash }
        member.validations[:shape] = shape

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /cannot contain itself.*shape member `a`/)
      end

      # A nested shape reused by two SIBLING members multiplies the distinct property paths beneath it: each
      # level doubles them, so N levels name 2^N properties. Shallow sharing — what anyone writes by hand — is
      # legal and cheap, and the walk remembers shapes it has already verified so each is checked once.
      def shared_sibling_shape(depth)
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }
        depth.times do
          shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: }),
                              Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: })],
                    container: Hash }
        end
        shape
      end

      it "declares a nested shape shared between sibling members, without re-walking each route" do
        shape = shared_sibling_shape(10)
        elapsed = nil

        expect { elapsed = Benchmark.realtime { build_axn { expects :payload, type: Hash, shape: } } }.not_to raise_error
        expect(elapsed).to be < 1.0
      end

      # Past a point that sharing is not a graph anything can walk cheaply: the PATHS are exponential, and every
      # walk of a stored graph pays one step per path — runtime validation on each call, and redaction once per
      # contract or per logged call for an instance-resolved `sensitive:` (measured: 786,000 paths ≈ 1.3s per log
      # line, ≈2s for the one derivation). Rejecting at declaration is the better of the two outcomes.
      #
      # Deliberately about the GRAPH, not about emitted properties: see `stored_shape_traversal_spec.rb` for the
      # separate, plan-derived bound on what a schema emits.
      it "rejects sharing deep enough that the path count is exponential" do
        shape = shared_sibling_shape(18)

        expect { project_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /has more than 25000 member paths/)
      end

      # The graph bound counts paths one at a time as well as by subtree: a single flat shape past the bound is
      # rejected on the per-member charge, where the diamond above is caught by the shared-subtree total.
      it "rejects one flat shape with more paths than the bound" do
        members = Array.new(25_001) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /has more than 25000 member paths/)
      end

      # The emitted-property bound is DERIVED from the emitter's own plan, so a shape whose members never become
      # properties costs nothing against it. A scalar `of:` is the clearest case: the members are validated off
      # an element that stays a String, and the schema names none of them.
      #
      # Sized to make the derivation observable: 26 fields x 1,000 members is 26,000 members — past the
      # emitted-property bound if they were charged — while each field's own graph is 1,000 paths, far inside the
      # separate bound on graph size. Predicting instead of deriving rejects this contract; deriving projects it.
      def wide_contract(per_field:, **options)
        members = Array.new(per_field) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
        build_axn do
          26.times { |f| expects :"f#{f}", shape: { members:, container: options[:container] }, **options.except(:container) }
        end
      end

      it "does not charge members the schema never emits" do
        klass = wide_contract(per_field: 1_000, type: Array, of: String, container: Array)

        expect(klass.input_schema.dig(:properties, :f0)).to eq({ type: "array", items: { type: "string" }, minItems: 1 })
      end

      # The corollary in the other direction: the same width of members that DO emit is still charged, and still
      # capped, so deriving has not simply disarmed the bound.
      it "still charges and still caps members the schema does emit" do
        expect { wide_contract(per_field: 1_000, type: Hash, container: Hash).input_schema }
          .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
      end

      # Whether a config emits anything AT ALL is the same question one level up, and it is SubfieldTree's to
      # answer: a config rooted at `on: :ambient_context` is never attached to a tree, so the projection is an
      # empty object however many are declared. Charging one property per config (plus every member of its shape)
      # rejected a contract whose schema names nothing.
      # A type whose members are past the emitted bound on their own, so every example below reads as "charged
      # or not charged" with nothing else in play.
      def wide_type = Data.define(*Array.new(26_000) { |i| :"m#{i}" })

      describe "a config the emitter represents nowhere" do
        it "charges nothing for an ambient-rooted config, and projects an empty object" do
          klass = build_axn do
            expects :items, on: :ambient_context, type: Array, of: Data.define(*Array.new(26_000) { |i| :"m#{i}" }), optional: true
          end

          expect(klass.input_schema).to eq({ type: "object", properties: {} })
        end

        it "charges nothing for an ambient-rooted shape either" do
          members = Array.new(1_000) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
          klass = build_axn do
            26.times { |f| expects :"f#{f}", on: :ambient_context, type: Hash, shape: { members:, container: Hash }, optional: true }
          end

          expect(klass.input_schema).to eq({ type: "object", properties: {} })
        end

        # A DEEP subfield under a parent that cannot hold object properties is omitted with its whole subtree
        # (reported through dropped_deep_subfields), so it names no property either.
        it "charges nothing for a dropped deep subfield" do
          wide = wide_type
          klass = build_axn do
            expects :payload, type: Hash do
              field :bar, type: [Hash, Array]
            end
            expects :baz, on: "payload.bar", type: Array, of: wide, optional: true
          end

          expect(klass.input_schema.dig(:properties, :payload, :properties, :bar)).not_to have_key(:properties)
          expect(Axn::Internal::Reflection::Schema.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs).map(&:field))
            .to eq([:baz])
        end

        # ...and the SAME rule at depth 1, which `dropped` does not record: the emitter blocks at the parent
        # whatever the depth, so the charge has to ask the blocking predicate rather than the dropped list.
        it "charges nothing for a depth-1 subfield under a model: parent" do
          wide = wide_type
          klass = build_axn do
            expects :thing, model: Struct.new(:id), optional: true
            expects :leaf, on: :thing, type: Array, of: wide, optional: true
          end

          expect(klass.input_schema[:properties].keys).to eq([:thing_id])
        end

        # A model: route emits `<field>_id` INSTEAD of the field, at any depth, so on input its own declared type
        # names no property either. Charged from the plan, which now says so, rather than from the emitter's branch.
        it "charges nothing for a model: route's own type on input" do
          wide = wide_type
          klass = build_axn { expects :thing, model: Struct.new(:id), type: Array, of: wide, optional: true }

          expect(klass.input_schema[:properties].keys).to eq([:thing_id])
        end

        # The control in the other direction: OUTPUT emits the field itself, so the same type is charged there.
        it "still charges a model: route's type on output, where the field is emitted" do
          wide = wide_type

          expect { build_axn { exposes :thing, model: Struct.new(:id), type: Array, of: wide, optional: true }.output_schema }
            .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end
      end

      # The other half of "ask the emitter": WHICH config the projection builds each property from. Reading the
      # emitter's own plan is exact only if the plan is given the config the emitter uses — and on OUTPUT it is
      # not the declared one. `build_property` first drops every validator entry a per-validator (nested) gate
      # could skip, because a gated constraint can't be promised outbound; the plan is derived from THAT. So a
      # gated `type:`/`of:`/`shape:` contributes no property name at all, and charging its members rejected a
      # contract over a schema that names none of them. The reduction now lives inside `shape_property_plan`
      # (Schema.effective_validations), so no caller can ask for a plan from a config the emitter would have
      # reduced first.
      describe "a config whose emitted schema is built from a reduced view of it" do
        def gated_type_axn(klass, direction, gate: true)
          member = Axn::Core::Contract::ShapeConfig.new(field: :keep, validations: {})
          shape = { members: [member], container: Hash }
          type = gate ? { klass:, if: :flag } : { klass: }
          build_axn { send(direction, :x, optional: true, shape:, type:) }
        end

        it "charges nothing for a per-validator-gated type: on output, and emits none of its members" do
          klass = gated_type_axn(Data.define(*Array.new(26_000) { |i| :"m#{i}" }), :exposes)

          expect(klass.output_schema.dig(:properties, :x, :properties).keys).to eq([:keep])
        end

        it "still charges an UNGATED type: of the same width on output" do
          wide = wide_type

          expect { gated_type_axn(wide, :exposes, gate: false).output_schema }
            .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        # The reduction is OUTPUT-only (input is static-maximal: a gate can only relax enforcement at runtime,
        # so the schema still advertises the type), which is why the same declaration is still charged inbound —
        # and the members really are emitted there.
        it "still charges a gated type: on INPUT, where the schema advertises it anyway" do
          wide = wide_type

          expect { gated_type_axn(wide, :expects).input_schema }.to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        it "emits a gated type's members inbound, so charging them is right there" do
          klass = gated_type_axn(Data.define(:sm1, :sm2), :expects)

          expect(klass.input_schema.dig(:properties, :x, :properties).keys).to eq(%i[sm1 sm2 keep])
        end

        # `of:` and `shape:` are entries of the same validations Hash, so the same gate drops either one — the
        # element type's own members stop reaching `items`, and a gated `shape:` stops emitting members at all.
        it "charges nothing for a gated of: on output" do
          wide = wide_type
          klass = build_axn { exposes :items, optional: true, type: Array, of: { klass: wide, if: :flag } }

          expect(klass.output_schema.dig(:properties, :items)).to eq({ type: %w[array null] })
        end

        it "charges nothing for a gated shape: on output" do
          members = Array.new(13_000) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
          klass = build_axn do
            exposes :x, optional: true, type: Hash, shape: { members:, container: Hash, if: :flag }
            exposes :y, optional: true, type: Hash, shape: { members:, container: Hash, if: :flag }
          end

          expect(klass.output_schema[:properties].values.map { |prop| prop.key?(:properties) }).to eq([false, false])
        end

        it "still charges the same two shapes UNGATED" do
          members = Array.new(13_000) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }

          expect do
            build_axn do
              exposes :x, optional: true, type: Hash, shape: { members:, container: Hash }
              exposes :y, optional: true, type: Hash, shape: { members:, container: Hash }
            end.output_schema
          end.to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        # The case where reading the plan's shape is the whole of it: a gated `shape:` BESIDE an ungated object
        # `of:` still leaves the plan EMITTED (the element type is an object, so an overlay would have applied),
        # while the shape it was derived from is gone. A walk that read the config's own `shape:` here charges
        # every member of an overlay `apply_structured_schema!` never merges.
        def gated_overlay_axn(per_field)
          members = Array.new(per_field) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
          build_axn do
            exposes :x, optional: true, type: Array, of: Hash, shape: { members:, container: Array, if: :flag }
            exposes :y, optional: true, type: Array, of: Hash, shape: { members:, container: Array, if: :flag }
          end
        end

        it "emits no member overlay for a gated shape: beside an ungated of:, and charges none" do
          expect(gated_overlay_axn(13_000).output_schema.dig(:properties, :x, :items)).to eq({ type: "object" })
        end

        it "still charges the same overlay UNGATED" do
          members = Array.new(13_000) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }

          expect do
            build_axn do
              exposes :x, optional: true, type: Array, of: Hash, shape: { members:, container: Array }
              exposes :y, optional: true, type: Array, of: Hash, shape: { members:, container: Array }
            end.output_schema
          end.to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        # A gated `type:` can also move WHERE the members land: with the array type gated off, the value is no
        # longer an array, so `items` is never emitted and the `of:` element type names nothing.
        it "charges nothing for an of: whose array type is gated off on output" do
          wide = wide_type
          klass = build_axn { exposes :items, optional: true, type: { klass: Array, if: :flag }, of: wide }

          expect(klass.output_schema[:properties]).to eq({ items: {} })
        end

        # A shape MEMBER is emitted through the same `build_property`, so its own gated type is reduced the same
        # way — and the walk recurses through members, so this is the charge one level down.
        it "charges nothing for a gated type on a shape member" do
          wide = wide_type
          inner = Axn::Core::Contract::ShapeConfig.new(
            field: :m,
            validations: { type: { klass: wide, if: :flag },
                           shape: { members: [Axn::Core::Contract::ShapeConfig.new(field: :keep, validations: {})], container: Hash } },
          )
          klass = build_axn { exposes :payload, optional: true, type: Hash, shape: { members: [inner], container: Hash } }

          expect(klass.output_schema.dig(:properties, :payload, :properties, :m, :properties).keys).to eq([:keep])
        end
      end

      # A wire path declared by TWO routes is one merged node, and the emitter builds its object property from
      # ONE of them (`Schema.property_representative` — the first non-model route). The other route is enforced
      # at runtime but its `shape:`/`of:` is never emitted, so charging it rejected a contract over a schema
      # that does not carry it.
      describe "a second route to a wire path the emitter already built" do
        def merged_axn(first_of:, second_of:)
          build_axn do
            expects :a, type: Hash, optional: true
            expects :b, on: :a, as: :bb, type: Hash, optional: true
            expects :c, on: "a.b", optional: true, type: Array, of: first_of
            expects :c, as: :c2, on: :bb, optional: true, type: Array, of: second_of
          end
        end

        it "charges nothing for the second route's of:, which is never emitted" do
          wide = wide_type
          klass = merged_axn(first_of: Data.define(:sm1), second_of: wide)

          expect(klass.input_schema.dig(:properties, :a, :properties, :b, :properties, :c, :items, :properties).keys).to eq([:sm1])
        end

        it "still charges the route the property IS built from" do
          wide = wide_type

          expect { merged_axn(first_of: wide, second_of: Data.define(:sm1)).input_schema }
            .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end
      end

      # The two remaining input cases, both reachable only by ASSIGNING configs onto a class — which is the route
      # this whole walk has to stay bounded for, and the one where a config carries whatever its author built.
      describe "an assigned top-level config the input schema treats differently" do
        def assigned(*validations_list)
          klass = build_axn { expects :other, optional: true }
          configs = validations_list.each_with_index.map do |validations, i|
            Axn::Core::Contract::FieldConfig.new(field: :x, reader_as: :"x#{i}", validations:)
          end
          klass.internal_field_configs = (klass.internal_field_configs + configs).freeze
          klass
        end

        def typed(klass) = { type: Array, of: { klass: }, optional: true }

        # `build_input` writes one property per WIRE KEY (`properties[config.field] = prop`), so when two configs
        # share one the later write wins and the earlier config's type names nothing.
        it "charges nothing for a config whose property a later one overwrites" do
          klass = assigned(typed(wide_type), typed(Data.define(:sm1)))

          expect(klass.input_schema.dig(:properties, :x, :items, :properties).keys).to eq([:sm1])
        end

        it "still charges the config whose write survives" do
          expect { assigned(typed(Data.define(:sm1)), typed(wide_type)).input_schema }
            .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        # `build_output` writes one property per wire key the same way, so the same rule holds outbound: the later
        # write is the property, and the earlier config's type names nothing.
        it "charges nothing for an OUTPUT config whose property a later one overwrites" do
          klass = build_axn { exposes :other, optional: true }
          configs = [typed(wide_type), typed(Data.define(:sm1))].each_with_index.map do |validations, i|
            Axn::Core::Contract::FieldConfig.new(field: :x, reader_as: :"x#{i}", validations:)
          end
          klass.external_field_configs = (klass.external_field_configs + configs).freeze

          expect(klass.output_schema.dig(:properties, :x, :items, :properties).keys).to eq([:sm1])
        end

        # And a field named in EXCLUDED_FROM_INPUT_SCHEMA is skipped outright — no property, no shape, no id.
        # `ambient_context` is a reserved field name, so only an assigned config can carry one.
        it "charges nothing for a config the input schema excludes by name" do
          wide = wide_type
          klass = build_axn { expects :other, optional: true }
          excluded = Axn::Core::Contract::FieldConfig.new(field: :ambient_context, reader_as: :ambient_context,
                                                          validations: { type: Array, of: { klass: wide }, optional: true })
          klass.internal_field_configs = (klass.internal_field_configs + [excluded]).freeze

          expect(klass.input_schema[:properties].keys).to eq([:other])
        end

        # A member with no name is one `named_members` filters out, so the emitter names no property for it and
        # never reaches its nested shape either — charging it (and walking it) counted 26,000 properties against a
        # schema naming none. Assigned, because the declaration walk rejects a nameless member outright.
        it "charges nothing for a shape member the emitter names no property for" do
          members = Array.new(26_000) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
          nameless = Class.new do
            def initialize(members) = @members = members
            def validations = { shape: { members: @members, container: Hash } }
          end.new(members)
          klass = build_axn { expects :other, optional: true }
          config = Axn::Core::Contract::FieldConfig.new(
            field: :p, reader_as: :p,
            validations: { type: { klass: Hash }, optional: true, shape: { members: [nameless], container: Hash } }
          )
          klass.internal_field_configs = (klass.internal_field_configs + [config]).freeze

          expect(klass.input_schema.dig(:properties, :p, :properties)).to eq({})
        end
      end

      # ...and an `of:` element type's OWN members reach `items` whether or not a shape overlays them, so the
      # type's own properties are charged even when the overlay is not emitted.
      it "counts an of: element type's own members, which the schema does emit" do
        names = Array.new(26_000) { |i| :"m#{i}" }
        wide = Data.define(*names)

        expect { build_axn { expects :items, type: Array, of: wide }.input_schema }
          .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
      end

      # A UNION `of:` reaches `items` through one `anyOf` branch per element type, each carrying its own
      # `properties` — so the charge has to count every namespace of the type schema, not the node's own
      # properties (which are empty for a union). Reading one key off the plan counted zero for all 26 branches
      # and let a 26,000-property schema project.
      it "counts every anyOf branch of a union of:" do
        wides = Array.new(26) { |b| Data.define(*Array.new(1_000) { |i| :"b#{b}m#{i}" }) }

        expect { build_axn { expects :items, type: Array, of: wides, optional: true }.input_schema }
          .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
      end

      # Counting a branch for SIZE must not make it a claim space: branches are alternatives, so two of them
      # may legally name the same member. The collision verdict is read from the emitted schema, where the two
      # sit at different paths.
      it "does not turn a member name shared by two branches into a collision" do
        klass = build_axn { expects :items, type: Array, of: [Data.define(:shared, :only_a), Data.define(:shared, :only_b)], optional: true }

        expect(klass.input_schema.dig(:properties, :items, :items, :anyOf).map { |branch| branch[:properties].keys })
          .to eq([%i[shared only_a], %i[shared only_b]])
      end

      # The unit is an emitted PROPERTY PATH, not a declaration, because several declarations legally name ONE
      # property and the emitter merges them into a single Hash key. Charging per declaration rejected a contract
      # of legal merges at two-thirds of the cap: a `Data` type's 12,500 members overlaid by 12,500 same-named
      # shape members emits 12,501 properties and was charged 25,001.
      describe "declarations that MERGE onto one emitted property" do
        def merged_wide(count)
          names = Array.new(count) { |i| :"m#{i}" }
          data = Data.define(*names)
          members = names.map { |name| Axn::Core::Contract::ShapeConfig.new(field: name, validations: {}) }
          build_axn { expects :d, type: data, optional: true, shape: { members:, container: data } }
        end

        it "charges a merged pair once, so a contract inside the cap projects" do
          expect(merged_wide(12_500).input_schema.dig(:properties, :d, :properties).size).to eq(12_500)
        end

        # The cap is not thereby disarmed: the same shape past it is still rejected, on the properties it does emit.
        it "still rejects the same shape past the cap" do
          expect { merged_wide(25_000).input_schema }.to raise_error(ArgumentError, /names more than 25000 JSON properties/)
        end

        # The merge every author actually writes: a `shape:` member and a same-named subfield are two declarations
        # of one property (both enforced at runtime, one key in the schema).
        it "charges a shape member and a same-named subfield once" do
          member = [Axn::Core::Contract::ShapeConfig.new(field: :x, validations: {})]
          klass = build_axn do
            expects :f0, type: Hash, optional: true, shape: { members: member, container: Hash }
            expects :x, on: :f0, optional: true
          end

          expect(klass.input_schema.dig(:properties, :f0, :properties).keys).to eq([:x])
        end

        # A `model:` route emits `<field>_id` INSTEAD of the field, so that is the path it is charged at — which
        # is also what makes it merge with an explicitly declared `<field>_id` (the emitter writes the generated
        # one with `||=`, so the two are one property). Charged at the field's own path instead, this pair cost
        # two properties and named one.
        it "charges a model: route and an explicit <field>_id as the one property they emit" do
          finder = Struct.new(:id) { def self.find(id) = new(id) }
          names = Array.new(24_998) { |i| :"m#{i}" }
          data = Data.define(*names)
          members = names.map { |name| Axn::Core::Contract::ShapeConfig.new(field: name, validations: {}) }
          klass = build_axn do
            expects :d, type: data, optional: true, shape: { members:, container: data }
            expects :thing, model: finder, optional: true
            expects :thing_id, optional: true
          end

          expect(klass.input_schema[:properties].keys).to eq(%i[d thing_id])
        end
      end

      # An array's `items` (and one `anyOf` branch of a union) is a NAMESPACE, not a property — the emitter names
      # nothing there — so the path it contributes must not be charged. Both cases are written at exactly the cap,
      # where one spurious charge is the whole difference between projecting and being rejected.
      it "counts an array's items as a namespace rather than a property" do
        names = Array.new(24_999) { |i| :"m#{i}" }
        wide = Data.define(*names)
        klass = build_axn { expects :items, type: Array, of: wide, optional: true }

        expect(klass.input_schema.dig(:properties, :items, :items, :properties).size).to eq(24_999)
      end

      # The same for one `anyOf` branch of a multi-class `of:`: a branch is a namespace the type's own members
      # land in, not a property. 12,499 members in each of two branches is 24,999 properties with the field —
      # one inside the cap, so charging either branch segment would reject it.
      it "counts an anyOf branch as a namespace rather than a property" do
        wides = Array.new(2) { |b| Data.define(*Array.new(12_499) { |i| :"b#{b}m#{i}" }) }
        klass = build_axn { expects :items, type: Array, of: wides, optional: true }

        expect(klass.input_schema.dig(:properties, :items, :items, :anyOf).map { |branch| branch[:properties].size }).to eq([12_499, 12_499])
      end

      it "counts it as a namespace for a shape overlay too" do
        members = Array.new(24_999) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
        klass = build_axn { expects :items, type: Array, optional: true, of: Hash, shape: { members:, container: Array } }

        expect(klass.input_schema.dig(:properties, :items, :items, :properties).size).to eq(24_999)
      end

      # Two member names of one shape that are the same PROPERTY — a String and a Symbol spelling — are one key
      # in the emitted object, so they are one charge. The charge normalizes a name the way `member_properties`
      # keys it (String#to_sym, bound), rather than by spelling. Assigned, because the declaration walk rejects
      # the pair as a duplicate member long before any of this.
      it "charges a String-named and a Symbol-named member of one property once" do
        members = Array.new(24_999) { |i| Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: {}) }
        string_named = Class.new do
          def field = "m0"
          def validations = {}
        end.new
        klass = build_axn { expects :ignored, optional: true }
        config = Axn::Core::Contract::FieldConfig.new(
          field: :p, reader_as: :p,
          validations: { type: { klass: Hash }, optional: true, shape: { members: members + [string_named], container: Hash } }
        )
        klass.internal_field_configs = [config].freeze

        expect(klass.input_schema.dig(:properties, :p, :properties).size).to eq(24_999)
      end

      # The other direction the per-declaration charge was wrong in: an implicit intermediate key a dotted `on:`
      # introduces is a property of its own, and one config can introduce a hundred. They are SHARED nodes, so
      # they are charged by path — once each, however many configs pass through — which is exactly what charging
      # per config could not do.
      #
      # Assigned rather than declared only for speed: declaring 250 deep subfields costs seconds, and the bound
      # has to hold for an assigned config anyway.
      it "charges each implicit intermediate a dotted on: introduces" do
        klass = build_axn { expects :r, type: Hash, optional: true }
        subs = Array.new(250) do |i|
          on = (["r"] + Array.new(99) { |d| "i#{i}_#{d}" }).join(".")
          Axn::Core::Contract::FieldConfig.new(field: :"leaf#{i}", reader_as: :"leaf#{i}", on: on.to_sym, validations: { optional: true })
        end
        klass.subfield_configs = (klass.subfield_configs + subs).freeze

        expect { klass.input_schema }.to raise_error(ArgumentError, /names more than 25000 JSON properties/)
      end

      it "reaches that rejection quickly rather than walking the whole graph first" do
        shape = shared_sibling_shape(22)
        elapsed = Benchmark.realtime do
          build_axn { expects :payload, type: Hash, shape: }
        rescue ArgumentError
          nil
        end

        expect(elapsed).to be < 1.0
      end

      # A member name that is neither String nor Symbol renders a property through its `to_s`, so it reaches
      # every one of these checks — while its `inspect` is real caller code. Dispatching that `inspect` to
      # build the error the name caused lets the name replace that error with an exception of its own, and one
      # outside StandardError then escapes class definition. Named by class instead, as the serializer names a
      # colliding Hash key. (Reachable only as a shape member's name: the field path symbolizes every declared
      # name before any guard runs — asserted in the last example here.)
      describe "a member name that is neither String nor Symbol, whose inspect raises" do
        def exotic_name_class
          Class.new do
            def initialize(rendering) = @rendering = rendering
            def to_s = @rendering
            def inspect = raise(NotImplementedError, "hijacked from #inspect")
          end
        end

        # These two reached the collision and unrenderable-name checks before a member name had to be a String
        # or a Symbol. The type rule now rejects such a name outright, ahead of both — a strictly earlier and
        # simpler answer to the same defect. `_inspect_field_name`'s class-naming branch stays live and
        # covered by the block-form option example below, which runs before a ShapeConfig is constructed.
        # A ShapeConfig cannot be CONSTRUCTED with such a name, so the rejection lands before any declaration
        # — earlier than the collision and unrenderable-name checks that used to be the first to see it.
        it "cannot be constructed on a ShapeConfig at all" do
          exotic = exotic_name_class

          expect { Axn::Core::Contract::ShapeConfig.new(field: exotic.new("dup"), validations: {}) }
            .to raise_error(ArgumentError, /a shape member name must be a String or a Symbol \(got a name of class /)
        end

        it "names the offender by class rather than dispatching its inspect" do
          exotic = exotic_name_class

          expect { Axn::Core::Contract::ShapeConfig.new(field: exotic.new("bad\xFF".dup.force_encoding("ASCII-8BIT")), validations: {}) }
            .to raise_error(ArgumentError) { |error|
              expect(error.message).to include("must be a String or a Symbol", "Declare the member under a String or Symbol name")
              expect(error.message.encoding).to eq(Encoding::UTF_8)
              expect(error.message).to satisfy(&:valid_encoding?)
            }
        end

        # A duck-typed member never routes through that constructor, so the resolved-member walk is the second
        # enforcement point for the same rule — without it the whole class would stay open.
        it "is rejected at declaration on a duck-typed member, which bypasses the constructor" do
          members = [duck_typed_member(exotic_name_class.new("dup"))]

          expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
            .to raise_error(ArgumentError, /a shape member name must be a String or a Symbol/)
        end

        # The block form's own option-rejection messages name the member through the same helper, so they
        # carry the same hazard — a third route to it, found by auditing the helper's callers.
        it "reports a block-form option error naming the member by class" do
          name = exotic_name_class.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

          expect do
            build_axn do
              expects(:payload, type: Hash) { field name, model: true }
            end
          end.to raise_error(ArgumentError, /shape member `a name of class .*` does not support model:/)
        end

        # Every declared field name is symbolized before any guard runs, so `config.field` is always a Symbol
        # and these helpers can never meet an exotic name on the field path. Asserted so the reasoning behind
        # leaving the field-path messages untouched stays true rather than assumed.
        #
        # What CLOSES the field path is now the type rule rather than `to_sym`'s accident: such a name used to
        # be diagnosed as `NoMethodError: undefined method 'to_sym' for an instance of …`, naming neither the
        # DSL nor what was wrong with the value (PRO-3026). The name is still never reached by the field-path
        # messages — it is refused before one could be built — so the reasoning above holds either way.
        it "cannot reach the field path at all, which symbolizes every declared name" do
          klass = build_axn { expects "stringy", :symbolic }
          exotic = exotic_name_class.new("dup")

          expect(klass.internal_field_configs.map { |c| c.field.instance_of?(Symbol) }).to all(be(true))
          # Named by CLASS, so the offender's own `inspect` — which raises here — never runs while the verdict
          # is being built.
          expect { build_axn { expects exotic } }
            .to raise_error(ArgumentError, /a field name must be a String or Symbol naming an inbound field \(got a value of class /)
        end
      end

      # `NoMethodError` inherits `name` from `NameError`, which is where the missing name is STORED, so the
      # stored symbol is read through NameError's own implementation. A subclass overriding `name` to raise
      # would otherwise replace the declaration verdict from inside the line that decides it — putting axn's
      # own Symbol on the left of the comparison does not help, because reading `e.name` is itself a dispatch.
      it "reads a NoMethodError's stored name through NameError, not through a subclass override" do
        raising_name = Class.new(NoMethodError) do
          def name = raise(NotImplementedError, "hijacked from #name")
        end
        ghost = Class.new do
          def initialize(error_class) = @error_class = error_class

          # Every reader is `method_missing`-backed, which the method table declares nothing for, so the dispatch
          # fallback is the path reached — and the raised error stores the missing name exactly as an implicit
          # NoMethodError would.
          def method_missing(reader, *_args) = raise(@error_class.new("boom", reader)) # rubocop:disable Style/MissingRespondToMissing
        end
        members = [ghost.new(raising_name),
                   Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                   Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {})]

        # The ghost is read as ABSENT (its stored name matches what was asked for), which is what this pins:
        # the verdict is axn's own nameless-member error, not the `NotImplementedError` the subclass's `name`
        # raises — that would have escaped every rescue in the framework.
        expect { project_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /a shape member must answer to `field`/)
      end
    end
  end

  # A declared name is caller-supplied, and a String SUBCLASS can define the very methods these rules ask it:
  # `==`/`eql?` to compare it, `to_s` to render it. Every such dispatch on the way from "collision established"
  # to "error raised" is a chance for the name to raise INSTEAD of the report — replacing the verdict with its
  # own exception, which outside StandardError escapes every rescue that would have settled it.
  #
  # Only a config ASSIGNED onto a class reaches these rules as a String subclass (the DSL symbolizes every
  # declared name), which is exactly the route that carries whatever its author built.
  describe "a declared name whose own methods run while it is being reported" do
    def assigned(*fields, direction: :input)
      klass = build_axn
      configs = fields.each_with_index.map do |field, index|
        Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
      end
      writer = direction == :input ? :internal_field_configs= : :external_field_configs=
      klass.public_send(writer, configs.freeze)
      klass
    end

    def project(klass, direction) = direction == :input ? klass.input_schema : klass.output_schema

    # `eql?` is left alone deliberately: it is the merge rule itself, not a report. See the merge examples below.
    def raising_eq(spelling)
      Class.new(String) do
        def ==(_other) = raise(NotImplementedError, "hijacked from #==")
        def eql?(_other) = false
      end.new(spelling)
    end

    def raising_to_s(spelling)
      Class.new(String) do
        def to_s = raise(NotImplementedError, "hijacked from #to_s")
      end.new(spelling)
    end

    # Attribution recovers WHICH declarations collided by matching emitted paths. `Array#==` dispatches each
    # element's own `==`, and the guard around the attribution walk does not reach the lookup over its result —
    # so the enrichment could raise in place of the collision it was enriching.
    %i[input output].each do |direction|
      it "reports the #{direction} collision rather than running the name's ==" do
        klass = assigned(raising_eq("dup"), :dup, direction:)

        expect { project(klass, direction) }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /"dup" and :dup/)
      end
    end

    it "still names the unrenderable emitted name rather than running its ==" do
      klass = assigned(raising_eq("bad\xFF".dup.force_encoding("ASCII-8BIT")))

      expect { klass.input_schema }.to raise_error(ArgumentError, /holds bytes that have no UTF-8 rendering/)
    end

    # Bytes that are no valid Symbol either. The size guard keys a wire key by a plain COPY of the name rather
    # than by interning it, so such a name reaches the rule that reports it in its own terms instead of dying of
    # `EncodingError` in a guard that only wanted to count.
    it "reports a name whose bytes are neither UTF-8 nor a valid Symbol" do
      klass = assigned("bad\xFF".dup.force_encoding("UTF-8"))

      expect { klass.input_schema }.to raise_error(ArgumentError, /holds bytes that have no UTF-8 rendering/)
    end

    # Canonicalization is the rule's own input, so a dispatch there is a dispatch inside a verdict. The name that
    # OWNS the dispatch is refused a rule earlier now (see "a declared name that decides its own rendering"), which
    # is what these two keep honest: the refusal itself must not run the `to_s` either, at a node whose property
    # count and collisions the rule never gets to judge.
    it "refuses a lone name whose to_s raises without running it" do
      klass = assigned(raising_to_s("a"))

      expect { klass.input_schema }.to raise_error(ArgumentError, /"a" does not render through Ruby's own `to_s`/)
    end

    it "refuses such a name ahead of the collision it would otherwise be reported as" do
      klass = assigned(raising_to_s("dup"), :dup)

      expect { klass.input_schema }.to raise_error(ArgumentError, /"dup" does not render through Ruby's own `to_s`/)
    end

    # The bytes rule and the rendering rule both fire on this one, and the ORDER is deliberate: a name owning its
    # rendering has no single property to be, so the report says that rather than reporting a property nothing
    # would have emitted. Left as an example because the previous defect was in the other direction — the name's
    # `to_s` answering renderable on a second ask walked an unrenderable name straight through the bytes check —
    # and neither answer may admit it.
    it "refuses a name whose bytes have no UTF-8 rendering and whose to_s claims otherwise" do
      liar = Class.new(String) do
        def to_s = "renderable"
      end.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

      expect { assigned(liar).input_schema }.to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end

    # A name that is neither String nor Symbol renders through code of its own, so the DECLARATION path — which
    # compares a new name against the configs a class already carries — still has to read it, and still may read it
    # only once. (The projection refuses such a name outright; this is the check that runs before any projection.)
    def flipping_name(first, second)
      Class.new do
        define_method(:initialize) { @answered = false }
        define_method(:to_s) do
          was = @answered
          @answered = true
          was ? second : first
        end
      end.new
    end

    it "reports a duplicate against an exotic assigned name, whatever its to_s says next" do
      klass = assigned(flipping_name("dup", "other"))

      expect { klass.expects(:dup) }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "dup"/)
    end

    # The collision message names the whole resolved path, so an ancestor's name is rendered there as well as at
    # its own node. Deriving a segment twice would be reading one name twice; the memo is what makes it once. A
    # STRING ancestor is what exercises it now — an exotic one is refused before its children are judged (see
    # "a declared name that decides its own rendering") — and it is the same path assembly either way.
    it "names the whole resolved path from one rendering of the ancestor" do
      klass = build_axn
      parent = Axn::Core::Contract::FieldConfig.new(field: "p", reader_as: :p, default: {},
                                                    validations: { type: { klass: Hash }, allow_nil: true })
      children = [utf8_name, latin1_name].each_with_index.map do |name, index|
        Axn::Core::Contract::FieldConfig.new(field: name, reader_as: :"c#{index}", on: :p, validations: { allow_nil: true })
      end
      klass.internal_field_configs = [parent].freeze
      klass.subfield_configs = children.freeze

      expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /the JSON property "p\.café"/)
    end

    # The declaration path's own report: which of the two duplicate wordings a collision gets is "is it the same
    # raw spelling", and asking a name that with `==` let it answer with an exception instead.
    it "reports a duplicate against an assigned name rather than running its ==" do
      klass = assigned(raising_eq("dup"))

      expect { klass.expects(:dup) }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /"dup" and :dup both render as the JSON property "dup"/)
    end

    # The same check reads the name's canonical property, and reads it off a String's own BYTES. That is what the
    # declaration path needs of its own: it runs BEFORE any projection exists, so the rendering rule cannot refuse
    # such a name here, and a canonicalization that dispatched `to_s` would let the name raise in place of the
    # duplicate — during class definition, where a NotImplementedError escapes everything.
    it "reports a duplicate against an assigned name whose to_s raises, without running it" do
      klass = assigned(raising_to_s("dup"))

      expect { klass.expects(:dup) }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /"dup" and :dup both render as the JSON property "dup"/)
    end

    # Two names that are the same content in two objects are ONE property, exactly as two identical spellings
    # are: the emitter writes `properties[config.field]` per config, and the second write lands on the first
    # key. That merge is the schema's own Hash, and it stays that way.
    def two_plain_strings = %w[dup dup]
    def two_symbols = %i[dup dup]

    def two_subclass_instances
      subclass = Class.new(String)
      [subclass.new("dup"), subclass.new("dup")]
    end

    %i[two_plain_strings two_symbols two_subclass_instances].each do |fixture|
      it "merges #{fixture.to_s.tr('_', ' ')} onto one property" do
        expect(assigned(*send(fixture)).input_schema[:properties].size).to eq(1)
        expect(assigned(*send(fixture), direction: :output).output_schema[:properties].size).to eq(1)
      end
    end

    # ...and the size guard, which runs BEFORE the build to decide which config the emitter would have built a
    # shared wire key's property from, does not ask the name that question either. It cannot be observed through
    # a projection, because the emitter's own `properties` Hash asks `eql?` immediately afterwards and that
    # dispatch is the merge rule rather than a report (`Internal::Reflection::Schema` is deliberately not one of the layers
    # that refuse to dispatch) — so the guard is checked where it lives.
    it "decides which config owns a shared wire key without asking the name" do
      raising_eql = Class.new(String) do
        def eql?(_other) = raise(NotImplementedError, "hijacked from #eql?")
      end
      configs = [raising_eql.new("dup"), raising_eql.new("dup")].each_with_index.map do |field, index|
        Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
      end

      expect { Axn::Internal::Reflection::PropertyNames.send(:reject_oversized_schema!, configs, [], for_output: false) }.not_to raise_error
      expect { Axn::Internal::Reflection::PropertyNames.send(:reject_oversized_schema!, configs, [], for_output: true) }.not_to raise_error
    end
  end

  # The premise the other two rules rest on: a name has ONE property to be. Three readers read a property name —
  # these rules canonicalize it (a String by its own bytes, so no verdict runs the name's code), the emitter writes
  # it into `required` through its `to_s`, and `JSON.generate` renders a Hash key through that same `to_s` — so a
  # name that answers them differently is two properties wearing one declaration, and every downstream verdict about
  # it is about a property nothing emits.
  #
  # Reachable only through a config ASSIGNED onto a class: `expects`/`exposes` symbolize every declared name, a
  # subfield route is symbolized before any guard reads it, and a shape member is stored as the Symbol the
  # declaration walk judged.
  describe "a declared name that decides its own rendering" do
    def assigned_field(field, direction: :input, **opts)
      klass = build_axn
      config = Axn::Core::Contract::FieldConfig.new(field:, reader_as: :held, validations: { presence: true }, **opts)
      klass.public_send(direction == :input ? :internal_field_configs= : :external_field_configs=, [config].freeze)
      klass
    end

    # Bytes and rendering deliberately disagree: `String#hash`/`eql?` (and so the emitter's own `properties` Hash)
    # see "other", while `to_s` — what `JSON.generate` asks a Hash key, and what the emitter's `required` list asks
    # the name — says "dup".
    def masquerading_name(bytes: "other", rendering: "dup")
      Class.new(String) do
        define_method(:to_s) { rendering }
      end.new(bytes)
    end

    # THE DEFECT, at each of the three paths that can expose a projection. Two declarations, one emitted JSON
    # property, nothing raised: the rules judged "other" beside :dup and passed, and `JSON.generate` then emitted
    # `{"dup":{},"dup":{}}` — a parser keeps one of them, so the second declaration is gone with no signal. This is
    # the shape the whole file exists to reject, reached through the encoder rather than through a declaration.
    it "no longer lets two names emit one JSON property through the encoder" do
      %i[input output].each do |direction|
        klass = build_axn
        configs = [masquerading_name, :dup].each_with_index.map do |field, index|
          Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
        end
        klass.public_send(direction == :input ? :internal_field_configs= : :external_field_configs=, configs.freeze)

        expect { direction == :input ? klass.input_schema : klass.output_schema }
          .to raise_error(ArgumentError, /a field name becomes a JSON property name, and "other" does not render through Ruby's own `to_s`/)
      end
    end

    it "refuses it on the render path, which builds no schema of its own" do
      klass = assigned_field(masquerading_name, direction: :output, validations: { allow_nil: true })

      expect { Axn::Extensions::Serialization.render(klass.call) }
        .to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end

    # No second declaration is needed for the name to be undecidable, so none is required to refuse it: one such
    # name emitted a `required` entry for a property its own `properties` map does not define — a schema no input
    # can satisfy — and an adapter reading `properties.keys.map(&:to_s)` saw a property the body never carries.
    it "refuses a lone such name, with nothing for it to collide with" do
      expect { assigned_field(masquerading_name).input_schema }
        .to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end

    # A name that renders through code of its own is refused whether or not the two renderings agree TODAY: what is
    # unbounded is the body, not this instance of it, and a `to_s` returning the receiver's own bytes is exactly what
    # a later call need not do.
    it "refuses one whose rendering happens to agree with its bytes" do
      expect { assigned_field(masquerading_name(bytes: "same", rendering: "same")).input_schema }
        .to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end

    # The rule asks the OBJECT, not its class, because what will be dispatched is the whole question. This name is
    # also why that is not the whole fix: Ruby stores a plain String Hash key as a frozen copy of its bytes, so the
    # singleton never reached the emitted property the rule reads — it reached the `required` entry alone, which
    # named a property the schema does not define, from a single declaration. The emitter reads the one name once
    # now, inbound and outbound.
    it "keeps `required` and `properties` naming one property for a plain String carrying a singleton to_s" do
      name = "other".dup
      name.define_singleton_method(:to_s) { "dup" }

      expect(Axn::Internal::NativeMethods.native_name_rendering?(name)).to be(false)
      [assigned_field(name).input_schema, assigned_field(name, direction: :output).output_schema].each do |schema|
        expect(schema[:properties].keys.map { |key| String.new(key) }).to eq(["other"])
        expect(schema[:required]).to eq(["other"])
        # The entry is a String the schema OWNS, so a consumer rendering it (`required.map(&:to_s)`, which is what
        # an adapter does) reads the property too — handing back the name itself would move the divergence out one
        # level rather than close it.
        expect(schema[:required].map(&:to_s)).to eq(["other"])
      end
    end

    # An exotic name has one rendering rather than two, but it produces it per CALL — so the rule's answer and the
    # encoder's are one only if the body answers the same every time, which no guard can establish. The RULE asks it
    # nothing: the only read is the emitter's own, building the `required` entry for a schema this then refuses (the
    # emitter is deliberately not one of the layers that refuse to dispatch — see AGENTS.md), so the name is asked
    # once and no verdict is taken from the answer.
    it "refuses a name that is neither String nor Symbol, without asking it a second time" do
      rendered = 0
      exotic = Class.new do
        define_method(:to_s) do
          rendered += 1
          "dup"
        end
      end.new

      expect { assigned_field(exotic).input_schema }
        .to raise_error(ArgumentError, /a name of class .* does not render through Ruby's own `to_s`/)
      expect(rendered).to eq(1)
    end

    # A Symbol cannot reach this at all, and not by being checked: it takes no instance of a subclass (`new` is
    # undefined and `allocate` raises) and no singleton method, so `:x.to_s` is Symbol's own however it is reached.
    # Asserted rather than assumed, because the rule treats a Symbol as native WITHOUT a method lookup.
    it "cannot be reached by a Symbol at all" do
      expect { Class.new(Symbol).new("x") }.to raise_error(NoMethodError)
      expect { Class.new(Symbol).allocate }.to raise_error(TypeError)
      expect { :x.singleton_class }.to raise_error(TypeError)
      expect(Axn::Internal::NativeMethods.native_name_rendering?(:x)).to be(true)
    end

    # WHERE the rule fires is where the emitter keys a property by the name ITSELF, and that is the top level only:
    # `properties[config.field]`. A SUBFIELD's wire segment is interned from the name's rendering by `SubfieldTree`
    # (as a shape member's key is, and a `model:` route's generated id), so the emitted name is a Symbol — the
    # schema, its `required` list and the encoder all read that one Symbol, and there is no second candidate for the
    # rule to refuse. Stated as an example because "does this rule reach a subfield" is the first thing a reader
    # asks, and because it is what makes the emitted-name derivation load-bearing rather than incidental.
    it "has nothing to refuse in a subfield's name, which the emitter interns into its wire segment" do
      klass = build_axn
      parent = Axn::Core::Contract::FieldConfig.new(field: :payload, reader_as: :payload, default: {},
                                                    validations: { type: { klass: Hash }, allow_nil: true })
      child = Axn::Core::Contract::FieldConfig.new(field: masquerading_name, reader_as: :child, on: :payload,
                                                   validations: { presence: true })
      klass.internal_field_configs = [parent].freeze
      klass.subfield_configs = [child].freeze
      nested = klass.input_schema.dig(:properties, :payload)

      expect(nested[:properties].keys).to eq([:dup])
      expect(nested[:required]).to eq(["dup"])
    end

    # The complement, and the reason the rule asks about the `to_s` rather than about the CLASS: a String subclass
    # renders through String's own `to_s`, which returns the receiver's bytes, so it names exactly one property and
    # is as good a name as a plain String — including for the merge and the collision it takes part in.
    it "leaves a String subclass that has not redefined to_s exactly as it was" do
      subclass = Class.new(String)
      klass = assigned_field(subclass.new("other"))

      expect(klass.input_schema[:properties].keys.map { |key| String.new(key) }).to eq(["other"])
      expect(klass.input_schema[:required]).to eq(["other"])
      expect(Axn::Internal::NativeMethods.native_name_rendering?(subclass.new("other"))).to be(true)
    end

    it "still reports a subclass name that collides with a Symbol as the collision it is" do
      klass = build_axn
      configs = [Class.new(String).new("dup"), :dup].each_with_index.map do |field, index|
        Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
      end
      klass.internal_field_configs = configs.freeze

      expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /"dup" and :dup both resolve to the JSON property "dup"/)
    end

    # A member's name is never emitted as itself — the declaration walk stores the Symbol it judged, and
    # `member_properties` keys the property by it — so a member named with such a String is normalized rather than
    # refused, and the property it names is its bytes. Stated as an example because "which names does this rule
    # reach" is exactly what a reader needs to know.
    it "does not reach a shape member's name, which is stored as the Symbol it was judged under" do
      name = masquerading_name
      member = Struct.new(:field, :validations).new(name, { presence: true })
      klass = build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq([:other])
      expect(klass.input_schema.dig(:properties, :payload, :required)).to eq(["other"])
    end

    # The owner lookup goes through a BOUND `Object#method`, so a name that defines its own `#method` cannot answer
    # the question being asked about it — nor raise in place of the verdict, which outside StandardError escapes
    # every rescue above. Such a name is perfectly good: its `to_s` is still String's own.
    it "reads the method table rather than asking the name's own #method" do
      name = "other".dup
      name.define_singleton_method(:method) { |*| raise(NotImplementedError, "hijacked from #method") }

      expect(Axn::Internal::NativeMethods.native_name_rendering?(name)).to be(true)
      expect(assigned_field(name).input_schema[:properties].keys.map { |key| String.new(key) }).to eq(["other"])
    end

    # The one way the lookup itself can fail: a String that has UNDEF'd `to_s` resolves to no method, exactly as
    # `#method` would raise NameError for it. It renders through whatever `method_missing` serves, which is
    # emphatically not String's, so the answer is the same refusal rather than a NameError escaping the rule.
    it "refuses a String whose to_s has been undef'd" do
      undefd = Class.new(String) { undef_method :to_s }.new("other")

      expect(Axn::Internal::NativeMethods.native_name_rendering?(undefd)).to be(false)
      expect { assigned_field(undefd).input_schema }.to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end

    # And the type test is `case`/`when` (a C-level `Module#===`) rather than `is_a?`, which a name can override to
    # claim it is a String and route around the branch that would look up its `to_s`.
    it "refuses a name that merely claims to be a String" do
      liar = Class.new do
        def is_a?(_klass) = true
        def to_s = "dup"
      end.new

      expect(Axn::Internal::NativeMethods.native_name_rendering?(liar)).to be(false)
      expect { assigned_field(liar).input_schema }.to raise_error(ArgumentError, /does not render through Ruby's own `to_s`/)
    end
  end

  # Every check runs before the class is mutated, so a rescued declaration error leaves nothing behind: no
  # half-committed config for a name that was rejected, and no reader for it. A class that survived the raise
  # carrying either would validate or expose a field the author was told they had not declared.
  describe "the class a rescued declaration error leaves behind" do
    it "carries no config and no reader for the rejected declaration" do
      names = [utf8_name, latin1_name]
      klass = build_axn
      methods_before = klass.instance_methods(false) + klass.private_instance_methods(false)

      expect { klass.expects(*names) }.to raise_error(Axn::ContractViolation::DuplicateFieldError)

      expect(klass.internal_field_configs).to be_empty
      expect(klass.external_field_configs).to be_empty
      expect(klass.instance_methods(false) + klass.private_instance_methods(false)).to eq(methods_before)
    end
  end

  # The runtime defense this does NOT replace has its own coverage: a declaration check cannot see the keys
  # of a Hash the action builds during a call, so the serializer stays the last line for that case. It is
  # covered by the "colliding Hash keys" describe block in `spec/axn/internal/reflection/values_spec.rb`, which owns
  # every assertion about the serializer's own behavior — do not duplicate it here; a second copy would add
  # a second place to maintain the serialization surface from, for no added protection.
end
