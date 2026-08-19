# frozen_string_literal: true

RSpec.describe "recursive of:" do
  describe "an Array of Arrays" do
    let(:action) { build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } } }

    it "passes when every inner element matches" do
      expect(action.call(matrix: [[1, 2], [3]])).to be_ok
    end

    it "fails when an inner element does not match, naming both positions" do
      result = action.call(matrix: [[1, 2], [3, "four"]])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 1: element at index 1 is not a Integer")
    end

    it "fails when an outer element is not an Array" do
      result = action.call(matrix: [[1], 2])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 1 is not a Array")
    end
  end

  describe "declaration-time refusals" do
    it "refuses an of: bag naming no container but carrying of:" do
      expect { build_axn { expects :m, type: Array, of: { of: Integer } } }
        .to raise_error(ArgumentError, /names no container/)
    end

    # `klass:`, not `type:` — inside a bag it is `klass:` that plays `type:`'s role, and there is no `type:` at
    # that rung for the author to edit. The field-level spelling is unchanged (see of_validator_spec).
    it "refuses a nested of: under a scalar klass" do
      expect { build_axn { expects :m, type: Array, of: { klass: String, of: Integer } } }
        .to raise_error(ArgumentError, "of: requires klass: Array or Hash (got [String])")
    end

    it "refuses a nested of: under a union klass" do
      expect { build_axn { expects :m, type: Array, of: { klass: [Array, Hash], of: Integer } } }
        .to raise_error(ArgumentError, "of: requires klass: Array or Hash (got [Array, Hash])")
    end
  end

  describe "bounds" do
    def nested_of(depth)
      depth.zero? ? Integer : { klass: Array, of: nested_of(depth - 1) }
    end

    it "accepts a graph exactly at MAX_NESTING" do
      bag = nested_of(Axn::Internal::ShapeGraph::MAX_NESTING)
      expect { build_axn { expects :m, type: Array, of: bag } }.not_to raise_error
    end

    # One depth counter and one cycle guard across both edge types, but two vocabularies: the sentence names
    # the `of:` bag the author actually wrote, and prescribes a fix their declaration has somewhere to make.
    it "refuses a graph one level deeper" do
      bag = nested_of(Axn::Internal::ShapeGraph::MAX_NESTING + 1)
      expect { build_axn { expects :m, type: Array, of: bag } }
        .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
    end

    it "refuses an of: bag that contains itself" do
      bag = { klass: Array }
      bag[:of] = bag
      expect { build_axn { expects :m, type: Array, of: bag } }
        .to raise_error(ArgumentError, /an `of:` graph cannot contain itself/)
    end

    it "refuses an of: bag that contains itself two rungs up" do
      inner = { klass: Array }
      outer = { klass: Array, of: inner }
      inner[:of] = outer
      expect { build_axn { expects :m, type: Array, of: outer } }
        .to raise_error(ArgumentError, /an `of:` graph cannot contain itself/)
    end
  end

  # An element that is itself a map: the bag's `klass:` decides which grammar its own `of:` is held to, exactly
  # as a field's `type:` does — so the Hash arm of that dispatch is reachable from an Array's element bag.
  describe "an Array of maps" do
    let(:action) { build_axn { expects :rows, type: Array, of: { klass: Hash, of: { values: Integer } } } }

    it "passes when every entry of every element matches" do
      expect(action.call(rows: [{ a: 1 }, { b: 2, c: 3 }])).to be_ok
    end

    it "fails naming the element and the entry's ordinal" do
      result = action.call(rows: [{ a: 1 }, { b: "two" }])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 1: value at index 0 is not a Integer")
    end
  end

  # The member path canonicalizes and walks through different code (`_symbol_keyed_member_validations` and the
  # per-member loop, not `_parse_field_validations`), so every property above is asserted again there.
  describe "a nested of: on a shape member" do
    let(:action) do
      build_axn do
        expects :payload, type: Hash do
          field :matrix, type: Array, of: { klass: Array, of: Integer }
        end
      end
    end

    it "passes when every inner element matches" do
      expect(action.call(payload: { matrix: [[1, 2], [3]] })).to be_ok
    end

    it "fails naming the member and both positions" do
      result = action.call(payload: { matrix: [[1], [2, "three"]] })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("matrix element at index 1: element at index 1 is not a Integer")
    end

    it "refuses a member's of: bag that contains itself" do
      bag = { klass: Array }
      bag[:of] = bag
      expect do
        build_axn { expects(:payload, type: Hash) { field :m, type: Array, of: bag } }
      end.to raise_error(ArgumentError, /an `of:` graph cannot contain itself/)
    end

    # One depth budget across BOTH edge types: the member sits one level down, so the `of:` chain that is
    # exactly at the cap from a FIELD is one level over it from a member.
    it "charges the member's own level against the same depth budget the shape edge spends" do
      bag = { klass: Array }
      Axn::Internal::ShapeGraph::MAX_NESTING.times { bag = { klass: Array, of: bag } }
      expect do
        build_axn { expects(:payload, type: Hash) { field :m, type: Array, of: bag } }
      end.to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
    end
  end

  # A member supplied as a raw `shape:` kwarg never routes through `_parse_field_validations`, so the
  # declaration walk's own descent is the ONLY thing that canonicalizes and bounds its `of:` chain. The block
  # form reaches both, which is why its bounds are covered above and its canonicalization here.
  describe "a nested of: on a raw shape member" do
    let(:member) { Struct.new(:field, :validations) }

    def declared(validations)
      klass = member
      build_axn { expects :payload, type: Hash, shape: { members: [klass.new(:matrix, validations)] } }
    end

    it "canonicalizes and constrains the whole chain" do
      action = declared({ type: Array, of: { klass: Array, of: Integer } })

      expect(action.call(payload: { matrix: [[1], [2, 3]] })).to be_ok
      expect(action.call(payload: { matrix: [[1], ["x"]] }).exception.message)
        .to include("matrix element at index 1: element at index 0 is not a Integer")
    end

    it "refuses an of: bag that contains itself" do
      bag = { klass: Array }
      bag[:of] = bag
      expect { declared({ type: Array, of: bag }) }
        .to raise_error(ArgumentError, /an `of:` graph cannot contain itself/)
    end

    it "refuses a chain deeper than the shared depth budget allows from a member's position" do
      bag = { klass: Array }
      Axn::Internal::ShapeGraph::MAX_NESTING.times { bag = { klass: Array, of: bag } }
      expect { declared({ type: Array, of: bag }) }
        .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
    end
  end

  # An `of:` rung charges the member-path allowance exactly as a member does, out of the SAME budget — a bag
  # cannot be reached 25,000 times by a chain alone (the depth bound stops it at 64), but it can through a
  # nested shape two siblings share, where N levels of sharing are 2^N routes to the same rung.
  #
  # Sized so the charge itself is the difference: the leaf shape below is one member plus a two-rung `of:`
  # chain, so 13 levels of two-way sharing are 40,958 paths with the rungs charged and 24,574 without — over
  # the bound with, comfortably under it at both sizes if the rungs were free.
  describe "the member-path allowance" do
    def shared_sibling_shape(depth, leaf_validations)
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: leaf_validations)],
                container: Hash }
      depth.times do
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: }),
                            Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: })],
                  container: Hash }
      end
      shape
    end

    it "charges each of: rung, so sharing that would be legal without them is refused" do
      shape = shared_sibling_shape(13, { type: Array, of: { klass: Array, of: Integer } })

      expect { build_axn { expects :payload, type: Hash, shape: } }
        .to raise_error(ArgumentError, /has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths/)
    end

    it "leaves the same graph one level shallower declarable" do
      shape = shared_sibling_shape(12, { type: Array, of: { klass: Array, of: Integer } })

      expect { build_axn { expects :payload, type: Hash, shape: } }.not_to raise_error
    end
  end

  # The declaration walk refuses both a cyclic and an over-deep `of:` graph, so a DECLARED contract can be
  # neither — but a field config assigned onto a class passed no declaration walk and carries whatever its
  # author built. That is the same reachability bar the shape bounds are justified on
  # (`ShapeGraph::MAX_NESTING`'s own note), and the runtime walk needs its own guard for it: the alternative
  # outcome is `SystemStackError`, outside `StandardError`, which escapes the rescue meant to settle a result
  # and surfaces as an `exception` outcome carrying a stack overflow.
  describe "a graph the class merely holds" do
    def assigned(validations)
      klass = build_axn {}
      klass.internal_field_configs =
        [Axn::Core::Contract::FieldConfig.new(field: :m, reader_as: :m, validations:)].freeze
      klass
    end

    it "settles a self-referential of: bag over a self-referential value instead of overflowing the stack" do
      bag = { klass: Array, container: Array }
      bag[:of] = bag
      value = []
      value << value

      result = assigned({ of: bag }).call(m: value)

      expect(result.exception).to be_nil
      expect(result).to be_ok
    end

    it "still reports a real mismatch under that same bag, so the guard skips only the repeat" do
      bag = { klass: Array, container: Array }
      bag[:of] = bag
      # The bag says "an Array of Arrays, forever", so the Integer two levels in is a genuine failure the
      # guard must not swallow — a value-only ancestry, or a guard that bailed on the bag alone, would.
      result = assigned({ of: bag }).call(m: [[1]])

      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 0: element at index 0 is not a Array")
    end

    # A chain and a value nested to the same depth, so the walk actually descends every rung rather than
    # stopping early on a value that ran out.
    def chain(rungs)
      bag = { klass: Array, container: Array }
      value = []
      rungs.times do
        bag = { klass: Array, container: Array, of: bag }
        value = [value]
      end
      [bag, value]
    end

    def too_deep_message
      "an `of:` graph nests more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep"
    end

    it "refuses a chain deeper than MAX_NESTING rather than recursing through it" do
      bag, value = chain(Axn::Internal::ShapeGraph::MAX_NESTING + 2)

      result = assigned({ of: bag }).call(m: value)

      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to include(too_deep_message)
    end

    # One depth budget at runtime as at declaration. This chain is exactly at the cap on its own and one over
    # it with a `shape:` rung above, so the pair proves the counter is SHARED rather than restarted per edge —
    # with one counter each, 64 `of:` under 64 `shape:` would be 128 levels of live recursion.
    context "a chain that exactly fills the budget on its own" do
      let(:chain_at_cap) { chain(Axn::Internal::ShapeGraph::MAX_NESTING + 1) }

      it "validates when nothing sits above it" do
        bag, value = chain_at_cap

        expect(assigned({ of: bag }).call(m: value).exception).to be_nil
      end

      it "is refused once a shape member's own level is spent first" do
        bag, value = chain_at_cap
        member = Struct.new(:field, :validations).new(:inner, { of: bag })

        result = assigned({ shape: { members: [member], container: Hash } }).call(m: { inner: value })

        expect(result.exception).to be_a(ArgumentError)
        expect(result.exception.message).to include(too_deep_message)
      end
    end

    # REFLECTION descends the same edge, one `items:` per rung, so it needs the same bound and reports it with the
    # same sentence — the alternative is a `SystemStackError` raised out of `input_schema`, which no rescue settles.
    # The declared cap is what keeps this unreachable for anything `expects` accepted.
    describe "reflecting one" do
      it "refuses a chain deeper than MAX_NESTING rather than overflowing the stack" do
        bag, = chain(Axn::Internal::ShapeGraph::MAX_NESTING + 2)

        expect { assigned({ type: { klass: Array }, of: bag }).input_schema }
          .to raise_error(ArgumentError, /#{Regexp.escape(too_deep_message)}/)
      end

      # The same boundary the runtime pair above pins for a chain with nothing above it. The two counters are
      # NOT the same once a `shape:` rung sits above one: the runtime spends one budget across both edges,
      # while this counts only its own chain — so a member's over-cap `of:` raises on call and still reflects.
      # Looser never rejects a legal declaration, and no DECLARED graph reaches either bound.
      it "reflects a chain that exactly fills the budget" do
        bag, = chain(Axn::Internal::ShapeGraph::MAX_NESTING + 1)

        expect { assigned({ type: { klass: Array }, of: bag }).input_schema }.not_to raise_error
      end

      it "nests one items: per rung all the way down" do
        bag, = chain(3)

        items = assigned({ type: { klass: Array }, of: bag }).input_schema.dig(:properties, :m, :items)

        expect(items).to eq(type: "array", items: { type: "array", items: { type: "array", items: { type: "array" } } })
      end
    end
  end

  describe "the caller's bag is copied, not aliased" do
    it "does not carry a later mutation into a declared contract" do
      inner = { klass: Integer }
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: inner } }
      inner[:klass] = String

      expect(action.call(m: [[1]])).to be_ok
    end

    # The copy is entry-wise at every rung, so a union list two levels down is axn's own Array rather than the
    # one the caller still holds — the aliasing bug `detach_option_containers!` closes at the first rung.
    it "does not carry a later mutation of a nested union into a declared contract" do
      union = [Integer]
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: union } } }
      union << String

      expect(action.call(m: [[1]])).to be_ok
      expect(action.call(m: [["x"]])).not_to be_ok
    end

    # A Hash answering missing keys from a default cannot be carried into a contract (its options are not
    # entries, so the copy drops them) — refused at every rung, not only the first.
    it "refuses a defaulting Hash as a nested bag" do
      expect { build_axn { expects :m, type: Array, of: { klass: Array, of: Hash.new(String) } } }
        .to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end
  end

  # The OTHER inner-contract key. A `shape:` inside a bag names the members of the value AT THAT POSITION —
  # never "each element of it", which is the distributing reading `shape:` has only at a field under
  # `type: Array`. So the container it is gated on is the bag's own `klass:`, and the explicit "no gate"
  # sentinel where the bag names none.
  describe "a shape: inside an of: bag" do
    # A method rather than a `let`: `build_axn` `class_eval`s its block onto the action class, so `self` in
    # there is the class and a `let` helper is unreachable from inside it. Every example hoists the shape into
    # a LOCAL first, which the block closes over.
    def sku_shape
      { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
    end

    it "validates each element's members" do
      shape = sku_shape
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      expect(action.call(rows: [{ sku: "a" }])).to be_ok
      result = action.call(rows: [{ sku: 1 }])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 0: sku is not a String")
    end

    it "accepts a bag constraining by members alone, with no klass:" do
      shape = sku_shape
      action = build_axn { expects :rows, type: Array, of: { shape: } }

      expect(action.call(rows: [{ sku: "a" }])).to be_ok
      expect(action.call(rows: [{ sku: 1 }])).not_to be_ok
    end

    it "emits the members as items.properties" do
      shape = sku_shape
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      expect(action.input_schema.dig(:properties, :rows, :items)).to include(
        type: "object", properties: { sku: { type: "string" } },
      )
    end

    # A bag naming no class is the untyped-element case: on INPUT a client sends objects carrying the members,
    # which is what the field-level "no `of:` at all" branch already says.
    it "emits the members of a klass-less bag too" do
      shape = sku_shape
      action = build_axn { expects :rows, type: Array, of: { shape: } }

      expect(action.input_schema.dig(:properties, :rows, :items)).to include(
        type: "object", properties: { sku: { type: "string" } },
      )
    end

    # OUTPUT is the opposite: nothing names a class, so nothing proves the value serializes member-keyed, and
    # the node is left untyped rather than promising an object the serializer will not produce.
    it "withholds a klass-less bag's members on output" do
      shape = sku_shape
      action = build_axn { exposes :rows, type: Array, of: { shape: } }

      expect(action.output_schema.dig(:properties, :rows)).not_to have_key(:items)
    end

    it "recurses two containers deep with members at the bottom" do
      shape = sku_shape
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: } } }

      result = action.call(m: [[{ sku: 1 }]])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 0: element at index 0: sku is not a String")
    end

    it "still refuses a bag that constrains none of the three axes, naming all of them" do
      expect { build_axn { expects :rows, type: Array, of: { message: "nope" } } }
        .to raise_error(ArgumentError, "of: must constrain something — name the contents' class with `klass:`, " \
                                       "what is inside them with `of:`, or their members with `shape:`")
    end

    # A shape describes what is inside a STRUCTURED value, so a bag naming a scalar class has nothing for the
    # members to be read off — held to exactly the bar a field's `type:` is held to, and named by the key the
    # author wrote inside a bag.
    it "refuses a shape under a scalar klass:" do
      shape = sku_shape
      expect { build_axn { expects :rows, type: Array, of: { klass: String, shape: } } }
        .to raise_error(ArgumentError, "a shape inside an `of:` bag requires a single structured klass: " \
                                       "(Array, Hash, or a class) — got [String]")
    end

    it "refuses a shape under a union klass:" do
      shape = sku_shape
      expect { build_axn { expects :rows, type: Array, of: { klass: [Hash, Array], shape: } } }
        .to raise_error(ArgumentError, "a shape inside an `of:` bag requires a single structured klass: " \
                                       "(Array, Hash, or a class) — got [Hash, Array]")
    end

    # The field-level combination stays refused (PRO-3166 task 6 grants it): `shape:` there names the hash's
    # OWN members while `of:` names its values, which is a different pairing from the one inside a bag.
    it "leaves of: beside shape: on a Hash FIELD refused" do
      shape = sku_shape
      expect { build_axn { expects :m, type: Hash, of: { values: Integer }, shape: } }
        .to raise_error(ArgumentError, /of: beside shape: on a Hash is not supported yet/)
    end

    # ONE depth counter across both edges, spent at the rung a bag's own `shape:` adds. Three levels sit above
    # the chain below — the bag's `of:` rung, the shape node it carries, and the member — so the boundary is
    # exactly two rungs shallower than the cap. The PAIR is what pins it: drop the shape node's level and the
    # boundary moves, so the "refuses" example is the one that catches a restarted counter and the "accepts"
    # one is the control against an over-eager charge.
    describe "the depth budget" do
      def chain(depth)
        depth.zero? ? Integer : { klass: Array, of: chain(depth - 1) }
      end

      def declared(depth)
        member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: Array, of: chain(depth) })
        shape = { members: [member] }
        build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }
      end

      it "refuses the first chain whose deepest rung lands past the cap" do
        expect { declared(Axn::Internal::ShapeGraph::MAX_NESTING - 1) }
          .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
      end

      it "leaves the one rung shallower declarable" do
        expect { declared(Axn::Internal::ShapeGraph::MAX_NESTING - 2) }.not_to raise_error
      end
    end

    # A bag's `shape:` is caller-supplied and is detached before axn writes the derived container into it, on
    # the same terms `_derive_raw_shape_container!` documents — so a later mutation cannot change a declared
    # contract, and the caller's own Hash never acquires axn's derived key.
    it "copies the caller's shape rather than aliasing it" do
      shape = sku_shape
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }
      shape[:members] << Axn::Core::Contract::ShapeConfig.new(field: :qty, validations: { type: { klass: Integer } })

      expect(shape).not_to have_key(:container)
      expect(action.call(rows: [{ sku: "a" }])).to be_ok
    end

    # The container belongs to the POSITION, not to the node, and one walk's memo hands every reference to a
    # shared shape the SAME copy — so the derivation has to detach before it writes, or the last position
    # walked would decide the container for all of them.
    it "derives a container per position for one shape reused at two of them" do
      shape = sku_shape
      member = ->(name, validations) { Axn::Core::Contract::ShapeConfig.new(field: name, validations:) }
      action = build_axn do
        expects :payload, type: Hash, shape: { members: [
          member.call(:gated, { type: Array, of: { klass: Hash, shape: } }),
          member.call(:open, { type: Array, of: { shape: } }),
        ] }
      end

      containers = action.internal_field_configs.first.validations[:shape][:members]
                         .to_h { |m| [m.field, m.validations.dig(:of, :shape, :container)] }
      expect(containers).to eq(gated: Hash, open: Axn::Internal::ShapeGraph::ANY_CONTAINER)
    end
  end

  # Task 1 landed the sentinel with no direct consumer; a bag constraining by members alone is the first, so
  # this is where its behaviour is pinned.
  describe "the no-container-gate sentinel" do
    it "is a Module, so it satisfies the container check without a special case" do
      expect(Axn::Internal::ShapeGraph::ANY_CONTAINER).to be_a(Module)
    end

    it "names itself in prose rather than rendering as an anonymous module" do
      expect(Axn::Internal::ShapeGraph::ANY_CONTAINER.to_s).to eq("Axn::Internal::ShapeGraph::ANY_CONTAINER")
    end

    it "is what a klass-less bag's shape is gated on" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
      action = build_axn { expects :rows, type: Array, of: { shape: } }

      stored = action.internal_field_configs.first.validations.dig(:of, :shape, :container)
      expect(stored).to be(Axn::Internal::ShapeGraph::ANY_CONTAINER)
    end

    # No type gate under the sentinel: the members are read off whatever arrived, and `extractable?` still
    # reports a value they cannot be read from. A Struct is neither Hash nor Array, so a real container gate
    # would skip it entirely and the mismatch below would go unreported.
    it "applies no type gate, so members are read off a value of any class" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
      action = build_axn { expects :rows, type: Array, of: { shape: } }
      row = Struct.new(:sku).new(1)

      result = action.call(rows: [row])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 0: sku is not a String")
    end

    # Identity is asked with the sentinel as the RECEIVER, so nothing a caller supplies can answer the
    # question for it: a container whose own `equal?` says yes to everything is still type-gated.
    it "cannot be impersonated by a container answering equal? for itself" do
      liar = Class.new do
        def self.equal?(_other) = true
        def self.name = "Liar"
      end
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })],
                container: liar }
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      # Gated on the liar, which the Hash below is not an instance of — so the members are never read and the
      # `sku` mismatch goes unreported. Were the sentinel check asking the CONTAINER, it would answer yes and
      # the gate would be skipped.
      expect(action.call(rows: [{ sku: 1 }])).to be_ok
    end
  end

  # ONE path allowance per field declaration, spent across BOTH edges. Two independent allowances admitted a
  # field whose `shape:` and whose `of:` chain each sat just under the cap — twice the graph the bound exists
  # to permit, and unexploitable only until `shape:` joined the bag's grammar and the two edges could
  # interleave at field level.
  describe "the member-path allowance across both field edges" do
    def shared_sibling_shape(depth, leaf_validations)
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: leaf_validations)],
                container: Hash }
      depth.times do
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: }),
                            Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: })],
                  container: Hash }
      end
      shape
    end

    # 13 levels of two-way sharing charge 24,574 paths, so either edge alone declares. Together they are
    # 49,149 — the two graphs plus the `of:` rung between them — which one budget refuses and two admit.
    it "leaves each edge legal on its own" do
      field_shape = shared_sibling_shape(13, { type: String })
      inner_shape = shared_sibling_shape(13, { type: String })

      expect { build_axn { expects :m, type: Hash, shape: field_shape } }.not_to raise_error
      expect { build_axn { expects :rows, type: Array, of: { klass: Hash, shape: inner_shape } } }.not_to raise_error
    end

    it "refuses the declaration that spends both" do
      field_shape = shared_sibling_shape(13, { type: String })
      inner_shape = shared_sibling_shape(13, { type: String })

      expect do
        build_axn { expects :rows, type: Array, shape: field_shape, of: { klass: Hash, shape: inner_shape } }
      end.to raise_error(ArgumentError, /has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths/)
    end
  end

  # A member of a bag's shape is a member at an UNNAMED position, and it is held to exactly what its named
  # twin is held to. Two things had to be carried across the `OfValidator` boundary for that to be true: the
  # per-member classification tag `ShapeValidator` sets (dropped when the error was re-added by message
  # alone, so the settlement path counted it as the FIELD's own error), and the outbound refusal (whose walk
  # descended `validations[:shape]` only, so an option refused with a fix-stating message one level up
  # declared cleanly here and did nothing).
  describe "user_facing: on a bag-shape member" do
    def member(**kwargs)
      Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }, **kwargs)
    end

    it "refuses an opted-in member on exposes, exactly as the field-level position does" do
      shape = { members: [member(user_facing: true)] }

      expect { build_axn { exposes :rows, type: Array, of: { klass: Hash, shape: } } }
        .to raise_error(ArgumentError, /shape member `sku` does not support user_facing: on exposes/)
    end

    it "refuses one nested a container deeper" do
      shape = { members: [member(user_facing: true)] }

      expect { build_axn { exposes :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: } } } }
        .to raise_error(ArgumentError, /shape member `sku` does not support user_facing: on exposes/)
    end

    it "refuses one hanging off a field-shape member's own of: chain" do
      inner = { members: [member(user_facing: true)] }
      outer = { members: [Axn::Core::Contract::ShapeConfig.new(field: :rows,
                                                               validations: { type: Array, of: { klass: Hash, shape: inner } })] }

      expect { build_axn { exposes :payload, type: Hash, shape: outer } }
        .to raise_error(ArgumentError, /shape member `sku` does not support user_facing: on exposes/)
    end

    it "leaves an un-opted member declarable on exposes" do
      shape = { members: [member] }

      expect { build_axn { exposes :rows, type: Array, of: { klass: Hash, shape: } } }.not_to raise_error
    end

    # A member that never opted in forces the whole failure dev-facing, whatever the FIELD declared — the
    # per-member classification PRO-2925 introduced. Untagged, the member's error was counted as the field's
    # own and inherited its `user_facing:`, publishing a message the identical field-level declaration
    # withholds.
    it "keeps an un-opted member dev-facing under a user_facing: field" do
      shape = { members: [member] }
      action = build_axn { expects :rows, type: Array, user_facing: true, of: { klass: Hash, shape: } }

      expect(action.call(rows: [{ sku: 1 }]).error).to eq("Something went wrong")
    end

    it "composes an opted-in member's message, so the tag is forwarded rather than erased" do
      shape = { members: [member(user_facing: true)] }
      action = build_axn { expects :rows, type: Array, user_facing: true, of: { klass: Hash, shape: } }

      expect(action.call(rows: [{ sku: 1 }]).error).to eq("Rows element at index 0: sku is not a String")
    end

    it "carries the deeper member's intent through two containers" do
      shape = { members: [member] }
      action = build_axn { expects :m, type: Array, user_facing: true, of: { klass: Array, of: { klass: Hash, shape: } } }

      expect(action.call(m: [[{ sku: 1 }]]).error).to eq("Something went wrong")
    end
  end
end
