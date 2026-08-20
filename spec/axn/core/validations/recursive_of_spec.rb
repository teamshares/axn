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

  # `OfValidator#guard_contents_descent`'s cycle guard is keyed on the (value, contents_node) PAIR and pops
  # between siblings (mirroring `CycleGuard.guard`'s own ancestry semantics) — so the identical sub-array
  # reused BY REFERENCE at two sibling elements is a legitimate diamond, not a cycle, and each occurrence must
  # still validate its own contents rather than have the second silently skipped because the pair "looked"
  # already visited.
  describe "the same element value reused by reference at two sibling positions" do
    it "still validates the second occurrence's own contents, not just the first" do
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Array, of: Integer } } }
      shared = ["x"]

      result = action.call(m: [[shared, shared]])

      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 0: element at index 0: element at index 0 is not a Integer")
      expect(result.exception.message).to include("element at index 0: element at index 1: element at index 0 is not a Integer")
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

    # An empty class union is the silent no-op this option exists to refuse, arriving through `klass:` rather
    # than through an absent axis: `matches_axis?` holds a value to every class in the list, and an empty list
    # holds it to none. Emptiness is asked here exactly as the runtime asks it (`Array(...).empty?`), which is
    # also how `_reject_unusable_of_message!` asks it — one question, one answer, at every position a bag sits
    # at.
    describe "an empty klass: union" do
      empty_union_message =
        "of: klass: names an empty union, so this bag constrains nothing — a value held to every " \
        "class in an empty list is held to none, so every value at that position passes while the " \
        "schema emits `anyOf: []`, which nothing satisfies. Name the class(es) the contents must be, " \
        "or drop the empty klass: and constrain them with `of:` or `shape:`. (`of: []` is sugar for " \
        "`of: { klass: [] }`.)"

      it "refuses the bare `of: []` spelling, which is sugar for it" do
        expect { build_axn { expects :a, type: Array, of: [] } }
          .to raise_error(ArgumentError, empty_union_message)
      end

      it "refuses the explicit `of: { klass: [] }` spelling" do
        expect { build_axn { expects :a, type: Array, of: { klass: [] } } }
          .to raise_error(ArgumentError, empty_union_message)
      end

      it "refuses it on a map's values: axis, where the sibling `of: { values: [] }` is refused already" do
        expect { build_axn { expects :a, type: Hash, of: { values: { klass: [] } } } }
          .to raise_error(ArgumentError, empty_union_message)
      end

      it "refuses it on a map's keys: axis" do
        expect { build_axn { expects :a, type: Hash, of: { keys: { klass: [] } } } }
          .to raise_error(ArgumentError, empty_union_message)
      end

      it "refuses it one container down" do
        expect { build_axn { expects :a, type: Array, of: { klass: Array, of: { klass: [] } } } }
          .to raise_error(ArgumentError, empty_union_message)
      end

      # The control: a union with something in it still constrains, and still declares.
      it "leaves a union naming at least one class alone" do
        action = build_axn { expects :a, type: Array, of: [Integer, String] }

        expect(action.call(a: [1, "x"])).to be_ok
        expect(action.call(a: [1.5])).not_to be_ok
      end
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

  # The tests above multiply out through a REUSED shape, which pays its `of:` rungs once (the first walk) and
  # then re-charges the recorded total at every later reference (the memo-hit re-judge in `_walk_shape_graph!`)
  # — so removing the direct per-rung charge (`_spend_paths!(allowance, 1)` inside `_walk_inner_contracts!`)
  # never moves any of THOSE totals enough to matter; only the LAST reference of a shared shape ever skips its
  # own direct charge, and that is a rounding error against tens of thousands of paths. A raw `of:` BAG shared
  # directly has no memo of its own, so every reference pays this exact line — the only construction that can
  # tell its removal from its presence.
  #
  # `keys:` and `values:` legitimately share the identical bag object below — a diamond, not a cycle
  # (`CycleGuard.guard` pops the ancestry between them) — so this is also the control for the `of:`-edge cycle
  # guard beside it: an over-eager guard that never released a visited bag between siblings would refuse this
  # declaration outright rather than merely mis-charge it.
  describe "sibling reuse of a raw of: bag, with no shared shape to backfill the charge" do
    # No memo for a raw `of:` bag, so each `keys:`/`values:` pair doubles the walk below it: total paths charged
    # is 2^(depth+1) - 2 (measured), comfortably under MAX_MEMBER_PATHS at 13 levels and over it at 14.
    def axis_value(depth)
      depth.zero? ? Integer : { klass: Hash, of: map_bag(depth - 1) }
    end

    def map_bag(depth)
      v = axis_value(depth)
      { keys: v, values: v }
    end

    it "accepts 13 levels of sibling reuse" do
      bag = map_bag(13)
      expect { build_axn { expects :m, type: Hash, of: bag } }.not_to raise_error
    end

    it "refuses the same sharing one level deeper" do
      bag = map_bag(14)
      expect { build_axn { expects :m, type: Hash, of: bag } }
        .to raise_error(ArgumentError, /has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths/)
    end

    # The allowance is spent across both edges, so its message is parametrized on the edge the charge sits on
    # — exactly as the cycle and depth refusals beside it are. A graph with no shape and no members anywhere
    # was told "the shape on :m … Give each member its own nested shape", prescribing a fix its declaration
    # has nowhere to make.
    it "names the of: edge, not a shape, when nothing in the graph is a shape" do
      bag = map_bag(14)
      message = begin
        build_axn { expects :m, type: Hash, of: bag }
        nil
      rescue ArgumentError => e
        e.message
      end

      expect(message).to start_with("the `of:` graph on :m has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths — " \
                                    "a nested `of:` bag reused at sibling positions multiplies out")
      expect(message).to include("Give each nested bag contents of its own, or flatten the nesting.")
    end

    # The control: a graph that multiplies out through SHARED SHAPES keeps the shape wording, so the
    # parametrization did not simply rename one message.
    it "still names the shape edge when the sharing is a shape's" do
      shape = shared_sibling_shape(13, { type: Array, of: { klass: Array, of: Integer } })

      expect { build_axn { expects :payload, type: Hash, shape: } }
        .to raise_error(ArgumentError, /\Athe `shape:` graph on :payload has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths/)
    end

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

    # The same unguarded route through a map's axis, which is the other position a bag can sit at: the runtime
    # walk descends it under the one budget, so a self-referential axis bag cannot reach the stack either.
    def self_referential_axis_map
      axis = { klass: Hash, container: Hash }
      axis[:of] = { values: axis, container: Hash }
      { of: { values: axis, container: Hash } }
    end

    it "settles a self-referential values bag over a self-referential value" do
      value = {}
      value[:a] = value

      result = assigned(self_referential_axis_map).call(m: value)

      expect(result.exception).to be_nil
      expect(result).to be_ok
    end

    it "still reports a real mismatch under that same axis bag" do
      result = assigned(self_referential_axis_map).call(m: { a: { b: 1 } })

      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 0: value at index 0 is not a Hash")
    end

    # Reflection descends the axis under the same guard rather than a restarted one, so a cyclic axis is
    # reported as the cycle it is instead of reaching the stack — exactly what an element chain of the same
    # shape does, and the defect the author can act on: reporting a cycle as depth exhaustion 64 rungs later
    # sends them looking for nesting that is not there.
    it "refuses to reflect a cyclic values bag rather than recursing through it" do
      expect { assigned(self_referential_axis_map).input_schema }
        .to raise_error(ArgumentError, /an `of:` bag contains itself/)
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

      # The same boundary the runtime pair above pins for a chain with nothing above it: reflection spends no
      # rung entering a field's own first bag where the declaration walk does, so it sits exactly one rung
      # looser — which is the safe direction, since looser never refuses to reflect a contract `expects`
      # accepted.
      it "reflects a chain that exactly fills the budget" do
        bag, = chain(Axn::Internal::ShapeGraph::MAX_NESTING + 1)

        expect { assigned({ type: { klass: Array }, of: bag }).input_schema }.not_to raise_error
      end

      # One counter across BOTH edges here as at declaration and at runtime, which a per-chain counter is not:
      # a member's own `of:` re-enters the contents builder through `build_property`, so a graph alternating
      # the two edges spent no rung on any single counter and reached the stack instead of the cap. Pinned in
      # both directions — the at-cap graph still emits, the first one past it is refused — because an
      # over-eager charge here would refuse to reflect a contract the declaration walk accepts.
      describe "a graph alternating the of: and shape-member edges" do
        # One link: a bag whose `shape:` names a member whose own `of:` is the next link. `klass: Hash` is what
        # opens the overlay at all (`Schema.shape_overlay_applies?`) — with `klass: Array` the members never
        # emit and the alternation never happens.
        def alternating(links)
          return nil if links.zero?

          inner = alternating(links - 1)
          validations = { type: { klass: Array } }
          validations[:of] = inner if inner
          member = Struct.new(:field, :validations).new(:child, validations)
          { klass: Hash, container: Array, shape: { container: Hash, members: [member] } }
        end

        it "reflects an alternating chain that exactly fills the budget" do
          bag = alternating(Axn::Internal::ShapeGraph::MAX_NESTING + 1)

          expect { assigned({ type: { klass: Array }, of: bag }).input_schema }.not_to raise_error
        end

        it "refuses one link deeper rather than overflowing the stack" do
          bag = alternating(Axn::Internal::ShapeGraph::MAX_NESTING + 2)

          expect { assigned({ type: { klass: Array }, of: bag }).input_schema }
            .to raise_error(ArgumentError, /a `shape:` graph nests more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
        end

        # The cycle the alternation closes: a bag whose shape member points its `of:` back at that bag. Nothing
        # repeats within either edge's own chain, so a per-edge counter never accumulated and `input_schema`
        # raised `SystemStackError` — outside StandardError, escaping every rescue meant to settle it.
        it "reports a cycle closed across the hop instead of reaching the stack" do
          member = Struct.new(:field, :validations)
          bag = { klass: Hash, container: Array }
          bag[:shape] = { container: Hash, members: [member.new(:child, { type: { klass: Array }, of: bag })] }

          expect { assigned({ type: { klass: Array }, of: bag }).input_schema }
            .to raise_error(ArgumentError, /a `shape:` graph contains itself/)
        end
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

    # `container: Array` is the one class a shape reads perfectly well off and still may not be stored at a bag
    # position: `ShapeValidator` reads that key as "distribute over the elements" rather than as a gate. Both
    # ways of arriving at it are refused, because both produce a contract nobody could read off the
    # declaration — a `klass: Array` derivation validates the members one level below where they are written
    # while emitting `items: { type: "array" }` and publishing none of them, and an explicit `container: Array`
    # beside `klass: Hash` enforces nothing at all while the schema promises the members as `items.properties`.
    describe "an Array container on a bag's shape" do
      distributing_message =
        "a `shape:` inside an `of:` bag cannot sit at `container: Array` (on :rows) — `ShapeValidator` reads " \
        "that container as \"distribute over the elements\" rather than as a gate, so the members describe what " \
        "is inside each element instead of the element itself, and the emitted schema and the runtime disagree " \
        "about which value carries them. Where the members belong to the level below, write it as the nesting " \
        "it is (`of: { klass: Array, of: { shape: ... } }`), which emits `items.items.properties`; where they " \
        "belong to this level, name the class they are read off (`klass: Hash`, or the object's own class) and " \
        "leave the shape's `container:` to be derived."

      it "refuses a shape derived onto it by klass: Array" do
        shape = sku_shape
        expect { build_axn { expects :rows, type: Array, of: { klass: Array, shape: } } }
          .to raise_error(ArgumentError, distributing_message)
      end

      it "refuses one the shape names for itself" do
        shape = sku_shape.merge(container: Array)
        expect { build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } } }
          .to raise_error(ArgumentError, distributing_message)
      end

      it "refuses one the shape names for itself where the bag names no class" do
        shape = sku_shape.merge(container: Array)
        expect { build_axn { expects :rows, type: Array, of: { shape: } } }
          .to raise_error(ArgumentError, distributing_message)
      end

      # The recursion this branch adds says the refused thing, and says it in the document too.
      it "accepts the nesting the message points at, and emits the members there" do
        shape = sku_shape
        action = build_axn { expects :rows, type: Array, of: { klass: Array, of: { shape: } } }

        expect(action.input_schema.dig(:properties, :rows, :items, :items)).to include(
          type: "object", properties: { sku: { type: "string" } }, required: ["sku"],
        )
        expect(action.call(rows: [[{ sku: "a" }]])).to be_ok
        expect(action.call(rows: [[{ sku: 1 }]]).exception.message)
          .to include("element at index 0: element at index 0: sku is not a String")
      end

      # The control: the fold's own ungated element position is untouched — `type: Array, of: Array` beside a
      # block never names a container at a bag position, so it still declares and still validates.
      it "leaves the folded Array element alone, which names no container of its own" do
        action = build_axn do
          expects :rows, type: Array, of: Array do
            field :first, type: String, method_call: true
          end
        end

        expect(action.call(rows: [%w[a b]])).to be_ok
        expect(action.call(rows: [[1, 2]]).exception.message).to include("element at index 0: first is not a String")
      end
    end

    # The field-level pairing is the same complement one rung up: `shape:` names the hash's OWN members while
    # `of:` names what is left, so the two are not rivals. Granted in full below ("shape: beside of: on a
    # Hash"); asserted here so this section carries the contrast rather than an obsolete refusal.
    it "accepts of: beside shape: on a Hash FIELD, exempting the member it names" do
      shape = sku_shape
      action = build_axn { expects :m, type: Hash, of: { values: Integer }, shape: }

      expect(action.call(m: { sku: "a", count: 1 })).to be_ok
      expect(action.call(m: { sku: "a", count: "one" })).not_to be_ok
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

      # Reflection spends its own bound across the same two edges, so the deepest graph `expects` ACCEPTS is
      # the control against charging one rung too many there: a schema is not optional for a declared contract.
      it "reflects the deepest graph the declaration walk accepts" do
        expect { declared(Axn::Internal::ShapeGraph::MAX_NESTING - 2).input_schema }.not_to raise_error
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

  # The same inner-contract bag an Array's element takes, in the other container's two positions. One grammar
  # in three positions, so a map's values are held to exactly what an array's elements are.
  describe "an inner contract on a map axis" do
    # A method rather than a `let`: `build_axn` `class_eval`s its block onto the action class, so `self` in
    # there is the class and a `let` helper is unreachable from inside it.
    def sku_shape
      { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
    end

    it "validates each value's members, located by ordinal" do
      shape = sku_shape
      action = build_axn { expects :by_region, type: Hash, of: { values: { klass: Hash, shape: } } }

      expect(action.call(by_region: { "acme" => { sku: "a" } })).to be_ok
      result = action.call(by_region: { "acme" => { sku: 1 } })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 0: sku is not a String")
    end

    # The ordinal is the only locating token at every depth, bag or no bag: a validation message settles
    # unredacted, so rendering a key would publish exactly what a `sensitive:` declaration asks to be masked.
    it "never renders a key, so a sensitive map's keys cannot leak" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Integer } } }

      result = action.call(m: { "secret-customer-id" => "x" })
      expect(result.exception.message).not_to include("secret-customer-id")
      expect(result.exception.message).to include("value at index 0 is not a Integer")
    end

    it "takes a per-axis message:" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Integer, message: "must be a whole number" } } }

      expect(action.call(m: { a: "x" }).exception.message).to include("value at index 0 must be a whole number")
    end

    it "takes a message: on the keys axis, named by its own position" do
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: Symbol, message: "must be a symbol" } } }

      expect(action.call(m: { "a" => 1 }).exception.message).to include("key at index 0 must be a symbol")
    end

    it "validates a bag on the keys: axis, and emits nothing for it" do
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: String }, values: Integer } }

      expect(action.call(m: { "a" => 1 })).to be_ok
      expect(action.call(m: { a: 1 })).not_to be_ok
      expect(action.input_schema.dig(:properties, :m)).not_to have_key(:propertyNames)
    end

    it "reports both axes of one entry independently" do
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: Symbol }, values: { klass: Integer } } }

      message = action.call(m: { "a" => "b" }).exception.message
      expect(message).to include("key at index 0 is not a Symbol")
      expect(message).to include("value at index 0 is not a Integer")
    end

    it "descends a container nested inside a values bag" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Array, of: Integer } } }

      expect(action.call(m: { a: [1, 2] })).to be_ok
      expect(action.call(m: { a: [1, "two"] }).exception.message)
        .to include("value at index 0: element at index 1 is not a Integer")
    end

    it "descends a map nested inside a values bag" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, of: { values: Integer } } } }

      expect(action.call(m: { a: { b: 1 } })).to be_ok
      expect(action.call(m: { a: { b: "one" } }).exception.message)
        .to include("value at index 0: value at index 0 is not a Integer")
    end

    it "emits a map of shaped records as additionalProperties" do
      shape = sku_shape
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: } } }

      expect(action.input_schema.dig(:properties, :m, :additionalProperties)).to include(
        type: "object", properties: { sku: { type: "string" } },
      )
    end

    it "emits a container nested inside a values bag" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Array, of: Integer } } }

      expect(action.input_schema.dig(:properties, :m, :additionalProperties)).to include(
        type: "array", items: { type: "integer" },
      )
    end

    it "emits a map nested inside a values bag" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, of: { values: Integer } } } }

      expect(action.input_schema.dig(:properties, :m, :additionalProperties)).to include(
        type: "object", additionalProperties: { type: "integer" },
      )
    end

    it "still refuses a bag-level message:, which cannot say which axis failed" do
      expect { build_axn { expects :m, type: Hash, of: { values: Integer, message: "x" } } }
        .to raise_error(ArgumentError, /does not support message:/)
    end

    it "holds an axis bag to the same grammar an element bag is held to" do
      expect { build_axn { expects :m, type: Hash, of: { values: {} } } }
        .to raise_error(ArgumentError, "of: must constrain something — name the contents' class with `klass:`, " \
                                       "what is inside them with `of:`, or their members with `shape:`")
    end

    it "refuses an unknown key inside an axis bag, against the element bag's own whitelist" do
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer, values: Integer } } } }
        .to raise_error(ArgumentError, /of: does not support values:/)
    end

    # A bag INSIDE a union is not the nested-contract spelling — a union names types — so it keeps the
    # unsupported-token refusal the other non-type tokens get.
    it "still refuses a bag inside a union on an axis" do
      expect { build_axn { expects :m, type: Hash, of: { values: [String, { klass: Integer }] } } }
        .to raise_error(ArgumentError, /of: values: must name a type/)
    end

    it "stores a copy, so mutating the axis bag afterwards cannot change the contract" do
      bag = { klass: Integer }
      action = build_axn { expects :m, type: Hash, of: { values: bag } }
      bag[:klass] = String

      expect(action.call(m: { a: 1 })).to be_ok
      expect(action.call(m: { a: "one" })).not_to be_ok
    end

    describe "the bounds, shared with the element edge" do
      # A chain of `rungs` axis bags. A map's `of:` is the axis CONTAINER rather than a position of its own,
      # and an axis naming a bare type is no position either, so the chain is judged over depths 0..rungs-1 —
      # one shallower than the element bags an array's chain of the same spelling produces.
      def axis_chain(rungs)
        rungs.zero? ? Integer : { klass: Hash, of: { values: axis_chain(rungs - 1) } }
      end

      it "accepts a chain whose deepest axis rung lands exactly at the cap" do
        chain = axis_chain(Axn::Internal::ShapeGraph::MAX_NESTING + 1)
        expect { build_axn { expects :m, type: Hash, of: { values: chain } } }.not_to raise_error
      end

      # Reflection descends the same chain on a counter of its own, threaded across the map rungs — so a graph
      # the declaration walk ACCEPTS must reflect, or the two bounds disagree and a legal contract has no
      # schema. The at-cap fixture is the only place that can catch a map rung that restarted the count.
      it "reflects the at-cap chain rather than tripping reflection's own bound" do
        chain = axis_chain(Axn::Internal::ShapeGraph::MAX_NESTING + 1)
        action = build_axn { expects :m, type: Hash, of: { values: chain } }

        expect { action.input_schema }.not_to raise_error
      end

      it "refuses one axis rung deeper" do
        chain = axis_chain(Axn::Internal::ShapeGraph::MAX_NESTING + 2)
        expect { build_axn { expects :m, type: Hash, of: { values: chain } } }
          .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
      end

      # ONE depth counter across both edges. A chain alternating an axis rung with an element rung spends two
      # per turn, so half the cap's worth of turns is already past it — two counters would admit it.
      it "refuses a chain that alternates the two edges past the cap" do
        alternating = lambda do |turns|
          turns.zero? ? Integer : { klass: Hash, of: { values: { klass: Array, of: alternating.call(turns - 1) } } }
        end
        chain = alternating.call(Axn::Internal::ShapeGraph::MAX_NESTING)

        expect { build_axn { expects :m, type: Hash, of: { values: chain } } }
          .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
      end

      it "refuses a cyclic axis bag rather than recursing until the stack gives out" do
        axis = { klass: Hash }
        axis[:of] = { values: axis }

        expect { build_axn { expects :m, type: Hash, of: { values: axis } } }
          .to raise_error(ArgumentError, /an `of:` graph cannot contain itself/)
      end

      def shared_sibling_shape(depth)
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: { type: String })],
                  container: Hash }
        depth.times do
          shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: }),
                              Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: })],
                    container: Hash }
        end
        shape
      end

      # Both axes charge the ONE allowance the declaration mints: 13 levels of two-way sharing charge 24,574
      # paths and 12 charge 12,286, so either axis declares alone and the two together do not.
      it "leaves each axis's own graph legal on its own" do
        keys_shape = shared_sibling_shape(13)
        values_shape = shared_sibling_shape(12)

        expect { build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: keys_shape } } } }
          .not_to raise_error
        expect { build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: values_shape } } } }
          .not_to raise_error
      end

      it "refuses the declaration that spends both axes" do
        keys_shape = shared_sibling_shape(13)
        values_shape = shared_sibling_shape(12)

        expect do
          build_axn do
            expects :m, type: Hash, of: { keys: { klass: Hash, shape: keys_shape }, values: { klass: Hash, shape: values_shape } }
          end
        end.to raise_error(ArgumentError, /has more than #{Axn::Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths/)
      end
    end

    # `keys:` takes the whole bag grammar, not just `klass:` — a key that is itself a structured value has
    # members like any other position. It is also the newest surface here, and the one where an ordinal-only
    # message matters most: the descent runs against the caller's KEY object.
    describe "a bag on the keys: axis" do
      def sku_member
        { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
      end

      it "validates the members of each key, located by ordinal" do
        shape = sku_member
        action = build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: } } }

        expect(action.call(m: { { sku: "a" } => 1 })).to be_ok
        expect(action.call(m: { { sku: 2 } => 1 }).exception.message).to include("key at index 0: sku is not a String")
      end

      it "renders no part of the key, even while descending into it" do
        shape = sku_member
        action = build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: } } }

        message = action.call(m: { { sku: "secret-customer-id" } => 1, { sku: 2 } => 1 }).exception.message
        expect(message).not_to include("secret-customer-id")
        expect(message).to include("key at index 1: sku is not a String")
      end

      it "descends a container nested inside a keys bag" do
        action = build_axn { expects :m, type: Hash, of: { keys: { klass: Array, of: Integer } } }

        expect(action.call(m: { [1, 2] => :x })).to be_ok
        expect(action.call(m: { [1, "two"] => :x }).exception.message)
          .to include("key at index 0: element at index 1 is not a Integer")
      end

      it "emits nothing for a keys bag, however much it declares" do
        shape = sku_member
        action = build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: }, values: Integer } }

        expect(action.input_schema.dig(:properties, :m)).not_to have_key(:propertyNames)
        expect(action.input_schema.dig(:properties, :m, :additionalProperties)).to eq(type: "integer")
      end
    end
  end

  # A `shape:` that is not a Hash names no members, so nothing could be read off it. Every position that can
  # hold one classifies with `hash_or_nil` and skips what it cannot read, so it declared cleanly and then
  # failed EVERY call with a bare `ArgumentError: must supply :members`, naming neither the declaration nor
  # the option. FOUR positions, one refusal — and the message names which of them fired, so an author is not
  # told to fix a slot they did not write.
  describe "a shape: that is not a Hash" do
    def sku_shape
      { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
    end

    it "refuses one at the field's own shape:" do
      expect { build_axn { expects :m, type: Hash, shape: :junk } }
        .to raise_error(ArgumentError, /\A`shape:` on :m must be a Hash naming the members it describes \(got :junk\) — /)
    end

    it "refuses one at a shape member's own shape:" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: :junk })] }

      expect { build_axn { expects :m, type: Hash, shape: } }
        .to raise_error(ArgumentError, /\A`shape:` on shape member `a` must be a Hash naming the members it describes \(got :junk\) — /)
    end

    it "refuses one at the element position" do
      expect { build_axn { expects :rows, type: Array, of: { klass: Hash, shape: :junk } } }
        .to raise_error(ArgumentError, /\A`shape:` inside the `of:` bag on :rows must be a Hash naming the members it describes/)
    end

    it "refuses one on the values axis, named by that axis" do
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: :junk } } } }
        .to raise_error(ArgumentError, /\A`shape:` inside the `of: \{ values: … \}` bag on :m must be a Hash naming/)
    end

    it "refuses one on the keys axis, named by that axis" do
      expect { build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: 5 } } } }
        .to raise_error(ArgumentError, /\A`shape:` inside the `of: \{ keys: … \}` bag on :m must be a Hash naming/)
    end

    # The bag position inside a MEMBER's chain, where the enclosing declaration is the member rather than the
    # field — the two ingredients of the label are independent, so the pair has to be pinned.
    it "names the member when a bag inside one carries it" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a,
                                                               validations: { type: Array, of: { klass: Hash, shape: nil } })] }

      expect { build_axn { expects :m, type: Hash, shape: } }
        .to raise_error(ArgumentError, /\A`shape:` inside the `of:` bag on shape member `a` must be a Hash naming/)
    end

    it "refuses one a container deeper" do
      expect { build_axn { expects :rows, type: Array, of: { klass: Array, of: { klass: Hash, shape: 5 } } } }
        .to raise_error(ArgumentError, /`shape:` inside the `of:` bag on :rows must be a Hash naming/)
    end

    # Keyed on `key?`, so "supplied but naming nothing" is refused while a declaration that simply carries no
    # `shape:` stays the honest spelling of "no members declared".
    it "refuses a nil shape: supplied beside a klass:" do
      expect { build_axn { expects :rows, type: Array, of: { klass: Hash, shape: nil } } }
        .to raise_error(ArgumentError, /must be a Hash naming the members it describes \(got a value of class NilClass\)/)
    end

    it "leaves every position that carries no shape: alone" do
      shape = sku_shape
      expect { build_axn { expects :rows, type: Array, of: { klass: Hash } } }.not_to raise_error
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer } } } }.not_to raise_error
      expect { build_axn { expects :m, type: Hash, shape: } }.not_to raise_error
    end
  end

  # `on:` is admitted into a bag by the whitelist only so the context-scope guard gets to name the real
  # problem. That guard scans the FIELD's validator entries, so it saw the field's own `of:` and nothing
  # below it — while a bag one rung down, or on either map axis, had its shared options dropped outright
  # (`inner_contract_validations` copies out `of:` and `shape:` only).
  describe "on: inside an of: bag" do
    it "is refused at the element position" do
      expect { build_axn { expects :rows, type: Array, of: { klass: Integer, on: :create } } }
        .to raise_error(ArgumentError, /\A`on:` inside an `of:` bag on :rows names an ActiveModel validation context/)
    end

    it "is refused on the values axis" do
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer, on: :create } } } }
        .to raise_error(ArgumentError, /\A`on:` inside an `of:` bag on :m names an ActiveModel validation context/)
    end

    it "is refused on the keys axis" do
      expect { build_axn { expects :m, type: Hash, of: { keys: { klass: Symbol, on: :create } } } }
        .to raise_error(ArgumentError, /`on:` inside an `of:` bag on :m names an ActiveModel validation context/)
    end

    it "is refused a container deeper" do
      expect { build_axn { expects :rows, type: Array, of: { klass: Array, of: { klass: Integer, on: :create } } } }
        .to raise_error(ArgumentError, /`on:` inside an `of:` bag on :rows names an ActiveModel validation context/)
    end

    # The map's own `of:` bag is a bag too. It was reached by the ENTRY scan instead, so one defect read two
    # ways depending on which container the author wrote — `on:` inside of: on ["m"] here, `on:` inside an
    # `of:` bag on :rows one line up.
    it "is refused on a map's own of: bag, in the same words the array form uses" do
      expect { build_axn { expects :m, type: Hash, of: { values: Integer, on: :create } } }
        .to raise_error(ArgumentError, /\A`on:` inside an `of:` bag on :m names an ActiveModel validation context/)
    end

    # The control: `on:` at the DECLARATION level is axn's subfield parent and stays legal, as does a bag
    # carrying the shared options that actually apply to it.
    it "leaves a declaration-level on: and an ordinary bag alone" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :rows, on: :payload, type: Array, of: { klass: Integer, message: "x", allow_nil: true }
        end
      end.not_to raise_error
    end
  end

  # The other shared ActiveModel options split by POSITION rather than being uniformly live or uniformly dead,
  # which is why only one position refuses them. Where the bag is an ActiveModel validator ENTRY — the field's
  # own `of:`, and a nested element bag, which `inner_contract_validations` hands to the next level verbatim —
  # AM reads them and they work. An axis bag is never an entry, so they are dropped.
  describe "the shared validation options inside a bag" do
    it "are live at the field's own of: bag" do
      action = build_axn { expects :m, type: Array, of: { klass: Integer, if: -> { false } } }

      expect(action.call(m: ["x"])).to be_ok
    end

    it "are live at a nested element bag, which becomes the next level's validator entry" do
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Integer, if: -> { false } } } }

      expect(action.call(m: [["x"]])).to be_ok
      # The control, so the example above is a gate firing rather than a check that never ran.
      ungated = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Integer } } }
      expect(ungated.call(m: [["x"]])).not_to be_ok
    end

    # An axis is the one position that is never handed to ActiveModel, so admitting these would be admitting
    # an option nothing reads — the silent no-op the whole `of:` whitelist exists to refuse.
    it "are refused on the values axis, where nothing would read them" do
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer, if: :flag } } } }
        .to raise_error(ArgumentError, /\Aof: values: does not support if: on :m — an axis is the one position/)
    end

    it "are refused on the keys axis, naming every offender at once" do
      expect { build_axn { expects :m, type: Hash, of: { keys: { klass: Symbol, allow_nil: true, strict: true } } } }
        .to raise_error(ArgumentError, /\Aof: keys: does not support allow_nil:, strict: on :m/)
    end

    it "leaves on: to the context-scope guard, which names a different problem" do
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer, on: :create } } } }
        .to raise_error(ArgumentError, /\A`on:` inside an `of:` bag on :m names an ActiveModel validation context/)
    end

    # The reason the ban is axis-only rather than bag-wide: axn's own tolerance push-down writes
    # `allow_blank:`/`allow_nil:` into a validator entry, and a bag IS one at every other position. It never
    # writes them into an axis, which is what makes the narrow ban safe.
    it "still accepts the tolerance keys axn itself writes into a bag" do
      expect { build_axn { expects :rows, type: Array, of: Integer, optional: true } }.not_to raise_error
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Integer } }, optional: true } }.not_to raise_error
    end

    it "writes the tolerance pair onto the map bag and never into an axis" do
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Integer } }, optional: true }
      bag = action.internal_field_configs.first.validations[:of]

      expect(bag).to include(allow_blank: true, allow_nil: false)
      expect(bag[:values]).to eq(klass: Integer)
    end
  end

  # A `message:` replaces the type description a mismatch reports, so a bag naming no class has nothing for it
  # to replace: `matches_axis?` waves every value through an empty class list and the mismatch branch is never
  # reached. Reachable since `shape:` joined the bag grammar, and now at both map axes too.
  describe "message: in a bag that names no klass:" do
    def sku_shape
      { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
    end

    it "is refused beside a shape: at the element position" do
      shape = sku_shape
      expect { build_axn { expects :rows, type: Array, of: { shape:, message: "must be a record" } } }
        .to raise_error(ArgumentError, /\Aof: message: on :rows has nothing to describe — /)
    end

    it "is refused on the values axis" do
      shape = sku_shape
      expect { build_axn { expects :m, type: Hash, of: { values: { shape:, message: "must be a record" } } } }
        .to raise_error(ArgumentError, /\Aof: message: on :m has nothing to describe/)
    end

    # Emptiness is asked exactly as the runtime asks it, and `_reject_unconstraining_of_bag!` asks the same
    # question a step earlier — so an empty union never reaches THIS guard: the bag constrains nothing at all,
    # which is the larger defect and the one reported. Pinned so the two guards cannot drift into disagreeing
    # about which bags name a class.
    it "yields to the unconstraining refusal beside an empty union klass:" do
      expect { build_axn { expects :rows, type: Array, of: { klass: [], message: "x" } } }
        .to raise_error(ArgumentError, /\Aof: klass: names an empty union/)
    end

    it "leaves a message: beside a klass: alone, which is the form that fires" do
      action = build_axn { expects :rows, type: Array, of: { klass: Integer, message: "must be a whole number" } }

      expect(action.call(rows: ["x"]).exception.message).to include("element at index 0 must be a whole number")
    end

    it "leaves a klass-less bag with no message: alone" do
      shape = sku_shape
      expect { build_axn { expects :rows, type: Array, of: { shape: } } }.not_to raise_error
    end
  end
  # A Hash is the only container where `shape:` and `of:` name DIFFERENT nodes: the shape names specific keys,
  # the map names what is left. That is exactly how `additionalProperties` relates to `properties` in the
  # document this emits, so a key the shape names is exempt from the map contract — on BOTH axes.
  describe "shape: beside of: on a Hash" do
    subject(:action) do
      build_axn do
        expects :metrics, type: Hash, of: { values: Integer } do
          field :label, type: String
        end
      end
    end

    it "exempts a key the shape names from the map's values axis" do
      expect(action.call(metrics: { label: "q3", visits: 120 })).to be_ok
    end

    it "still holds an unshaped key to the values axis" do
      result = action.call(metrics: { label: "q3", visits: "lots" })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 1 is not a Integer")
    end

    # The emitter canonicalizes a member name with `to_sym`, but a runtime Hash arrives string-keyed for the
    # commonest payload shape there is (JSON), and extraction reads a member under either spelling. A
    # Symbol-only comparison would silently stop exempting for exactly those callers.
    it "exempts a STRING-keyed occurrence of the same member" do
      expect(action.call(metrics: { "label" => "q3", "visits" => 120 })).to be_ok
    end

    it "still validates the shape member itself" do
      result = action.call(metrics: { label: 5 })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("label is not a String")
    end

    it "counts an exempt key toward the ordinal, so positions name the entry the caller wrote" do
      result = action.call(metrics: { label: "q3", visits: "lots" })
      expect(result.exception.message).to include("index 1")
    end

    it "emits properties and additionalProperties at one node" do
      expect(action.input_schema[:properties][:metrics]).to include(
        type: "object",
        properties: { label: { type: "string", minLength: 1 } },
        required: ["label"],
        additionalProperties: { type: "integer" },
      )
    end

    # `keys:` emits nothing (every JSON object key is already a string), so there is no document to contradict
    # — and the symmetric rule is what stops `field :label` quietly acquiring a symbol-key requirement it
    # never asked for.
    it "exempts a shaped key from the keys: axis too" do
      keyed = build_axn do
        expects :m, type: Hash, of: { keys: Symbol, values: Integer } do
          field :label, type: String
        end
      end

      expect(keyed.call(m: { "label" => "q3", visits: 1 })).to be_ok
    end

    it "leaves a map with no shape governing every entry" do
      unshaped = build_axn { expects :m, type: Hash, of: { values: Integer } }

      expect(unshaped.call(m: { label: "q3" })).not_to be_ok
    end

    # The bag's own pairing rather than the field's: `klass: Hash` names the value at a map's `values:` axis,
    # and the shape beside it names that value's own keys.
    it "exempts a shaped key of a map nested inside a bag" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :label, validations: { type: { klass: String } })] }
      nested = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape:, of: { values: Integer } } } }

      expect(nested.call(m: { "acme" => { label: "q3", visits: 1 } })).to be_ok
      result = nested.call(m: { "acme" => { label: "q3", visits: "lots" } })
      expect(result).not_to be_ok
      expect(result.exception.message).to include("value at index 0: value at index 1 is not a Integer")
    end

    # A shape MEMBER's bag runs through the canonicalization seam TWICE, so the derived exempt set needs the
    # same drop-and-re-derive handling `container:` gets — without it the second pass reports axn's own key as
    # one the grammar does not support and fails a well-formed declaration.
    it "survives the second canonicalization pass over a shape member's bag" do
      member = build_axn do
        expects :payload, type: Hash do
          field :metrics, type: Hash, of: { values: Integer } do
            field :label, type: String
          end
        end
      end

      expect(member.call(payload: { metrics: { label: "q3", visits: 1 } })).to be_ok
      expect(member.call(payload: { metrics: { label: "q3", visits: "lots" } })).not_to be_ok
    end

    # The distributing spelling: the shape sits at the FIELD while the element's own map sits inside the bag,
    # and the emitter merges both into one `items` node — so the exemption has to reach a map whose shape
    # lives a rung above it, or the declaration contradicts the schema it publishes.
    describe "a shaped element that is itself a map" do
      subject(:action) do
        build_axn do
          expects :rows, type: Array, of: { klass: Hash, of: { values: Integer } } do
            field :label, type: String
          end
        end
      end

      it "exempts the shaped key from the element's values axis" do
        expect(action.call(rows: [{ label: "q3", visits: 120 }])).to be_ok
      end

      it "still holds an unshaped key of the element to the values axis" do
        result = action.call(rows: [{ label: "q3", visits: "lots" }])
        expect(result).not_to be_ok
        expect(result.exception.message).to include("element at index 0: value at index 1 is not a Integer")
      end

      it "still validates the element's shape member" do
        result = action.call(rows: [{ label: 5 }])
        expect(result).not_to be_ok
        expect(result.exception.message).to include("element at index 0: label is not a String")
      end

      it "emits properties and additionalProperties at the items node" do
        expect(action.input_schema[:properties][:rows][:items]).to include(
          type: "object",
          properties: { label: { type: "string", minLength: 1 } },
          additionalProperties: { type: "integer" },
        )
      end
    end

    # Deliberately still refused (see the design spec's Scope section): relaxing it would make the exempt set
    # everything the emitter puts in `properties` at that node — subfield leaves, dotted-`on:` segments,
    # `model:`'s generated id — none of which is knowable from the shape, where the set is derived.
    it "still refuses a subfield rooted at a map" do
      expect do
        build_axn do
          expects :m, type: Hash, of: { values: Integer }
          expects :sku, on: :m
        end
      end.to raise_error(ArgumentError, /not supported yet/)
    end
  end
end
