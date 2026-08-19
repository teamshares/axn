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
end
