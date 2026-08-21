# frozen_string_literal: true

# The stored shape of a container's contents. This is the regression net for the canonicalization
# (PRO-3166): a container's contents live in its `of:` bag at EVERY depth, so no consumer has two
# places to look. A seam still reading `validations[:shape]` for an Array-typed field fails here
# rather than silently stopping redacting/reflecting/descending.
RSpec.describe "canonical storage of a container's contents" do
  def validations_for(action) = action.internal_field_configs.first.validations

  it "stores an Array's element contract in the of: bag, with no top-level shape:" do
    action = build_axn do
      expects :rows, type: Array, of: Hash do
        field :sku, type: String
      end
    end
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v[:of]).to include(klass: Hash, container: Array)
    expect(v.dig(:of, :shape, :container)).to eq(Hash)
    expect(v.dig(:of, :shape, :members).map(&:field)).to eq([:sku])
  end

  it "stores a class-unconstrained element contract when there is no of:" do
    action = build_axn do
      expects :rows, type: Array do
        field :sku, type: String
      end
    end
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v.dig(:of, :container)).to eq(Array)
    expect(v.dig(:of, :klass)).to be_nil
    expect(v.dig(:of, :shape, :container)).to eq(Axn::Internal::ShapeGraph::ANY_CONTAINER)
    expect(v.dig(:of, :shape, :members).map(&:field)).to eq([:sku])
  end

  it "leaves a Hash's own shape at the field" do
    action = build_axn do
      expects :h, type: Hash do
        field :sku, type: String
      end
    end
    v = validations_for(action)

    expect(v[:of]).to be_nil
    expect(v.dig(:shape, :container)).to eq(Hash)
  end

  it "leaves a Data field's shape at the field" do
    point = Data.define(:x)
    action = build_axn do
      expects :pt, type: point do
        field :x, type: Integer
      end
    end

    expect(validations_for(action).dig(:shape, :container)).to eq(point)
  end

  it "leaves a map's of: bag alone" do
    action = build_axn { expects :m, type: Hash, of: { values: Integer } }
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v[:of]).to include(values: Integer, container: Hash)
  end

  it "refuses the flat form at a nested position too" do
    sku = Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })

    expect do
      build_axn do
        expects :outer, type: Hash do
          field :rows, type: Array, of: Hash, shape: { members: [sku] }
        end
      end
    end.to raise_error(ArgumentError, /`shape:` on shape member `rows` distributes over an Array's elements/)
  end

  it "keeps a map's shape: beside its of: at the field" do
    action = build_axn do
      expects :m, type: Hash, of: { values: Integer } do
        field :label, type: String
      end
    end
    v = validations_for(action)

    expect(v.dig(:shape, :container)).to eq(Hash)
    expect(v.dig(:of, :shaped_keys)).to eq([:label])
  end

  # The one node a distributing `shape:` and a bag's own `shape:` both describe. Both applied before the
  # canonicalization (two validators over one element) and both must still apply after it, from the one
  # slot the bag has: the members are unioned rather than one displacing the other.
  # A SCALAR `of:` beside a distributing shape reads the members off each element, which stays a scalar — the
  # emitter validates them without ever emitting them as properties (`Schema.shape_overlay_applies?`). The fold
  # cannot gate on a class a shape has no members to be read off, so the position stays ungated, which is what
  # the flat spelling always meant there: it named `Array` for the FIELD and nothing at all for the element.
  # (The bag spelling `of: { klass: String, shape: … }` refuses at declaration instead — that refusal is about
  # what an author WROTE, and this canonicalization changes storage rather than the surface.)
  it "leaves a scalar element's position ungated" do
    action = build_axn do
      expects :codes, type: Array, of: String do
        field :length, type: Integer, method_call: true
      end
    end
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v.dig(:of, :klass)).to eq(String)
    expect(v.dig(:of, :shape, :container)).to eq(Axn::Internal::ShapeGraph::ANY_CONTAINER)
    expect(action.call(codes: %w[abc])).to be_ok
    expect(action.input_schema.dig(:properties, :codes, :items)).to eq({ type: "string" })
  end

  # `container: Array` on a shape is not a gate — `ShapeValidator` reads it as "distribute over the elements"
  # — so the fold cannot store it for `of: Array` however readable the members are off an Array. There is no
  # spelling for "read members off this Array element" while that reading holds, and inventing one here would
  # read the members a level too deep and reject `[%w[a b]]`, naming a position the author never declared. The
  # position stays ungated, which is what the distributing spelling always meant at the element anyway.
  it "leaves an Array element's position ungated rather than reading its members one level too deep" do
    action = build_axn do
      expects :rows, type: Array, of: Array do
        field :first, type: String, method_call: true
      end
    end
    v = validations_for(action)

    expect(v.dig(:of, :klass)).to eq(Array)
    expect(v.dig(:of, :shape, :container)).to eq(Axn::Internal::ShapeGraph::ANY_CONTAINER)
    expect(action.call(rows: [%w[a b]])).to be_ok
    expect(action.call(rows: [[1, 2]]).exception.message).to include("element at index 0: first is not a String")
    # Emission is settled by the bag's `klass:`, never by the shape's container, so it is untouched: an Array
    # element is not an object, so the members are validated and never emitted as properties.
    expect(action.input_schema.dig(:properties, :rows, :items)).to eq({ type: "array" })
  end

  it "unions a distributing shape with the bag's own shape" do
    inner = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: { klass: String } })
    action = build_axn do
      expects :rows, type: Array, of: { klass: Hash, shape: { members: [inner] } } do
        field :sku, type: String
      end
    end
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v.dig(:of, :shape, :container)).to eq(Hash)
    expect(v.dig(:of, :shape, :members).map(&:field)).to contain_exactly(:a, :sku)
  end

  # The union is a MERGE of two member lists into one shape, so it can build what a single shape may never
  # hold: the same key twice. Written inside one block that raises already; arriving by the fold it declared
  # cleanly and produced exactly the consequences that refusal names — `required: ["sku", "sku"]` (which JSON
  # Schema requires to be unique), one `properties.sku`, and one of the two declarations silently unenforced,
  # because `ShapeValidator#member_validator_classes` keys members by `field` and a duplicate collapses.
  it "refuses a folded union that declares one member twice, naming both spellings" do
    inner = Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })

    expect do
      build_axn do
        expects :rows, type: Array, of: { klass: Hash, shape: { members: [inner] } } do
          field :sku, type: Integer
        end
      end
    end.to raise_error(Axn::ContractViolation::DuplicateFieldError,
                       "Duplicate shape member declared: :sku — the `shape:` inside the `of:` bag on :rows and " \
                       "the shape distributed over its elements both declare it, and the two member lists are " \
                       "unioned into one. The reflected schema would name it twice in `required:` while emitting " \
                       "one property for it, and only one of the two declarations would validate. Declare :sku " \
                       "in one of the two.")
  end

  # A member declared twice under one bag shape is the ordinary case and still raises where it always did, so
  # the fold's check adds a spelling rather than replacing one.
  it "still refuses a duplicate declared twice inside the bag's own shape" do
    members = [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }),
               Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: Integer } })]

    expect { build_axn { expects :rows, type: Array, of: { klass: Hash, shape: { members: } } } }
      .to raise_error(Axn::ContractViolation::DuplicateFieldError, /\ADuplicate shape member declared: :sku — two members of one shape/)
  end
end

# Canonicalization changes WHO produces each of the two message shapes — `OfValidator`'s own
# unpunctuated type report and the colon-prefixed delegation to the element's members — so byte
# identity is asserted rather than assumed.
RSpec.describe "message parity across the canonicalization" do
  let(:action) do
    build_axn do
      expects :rows, type: Array, of: Hash do
        field :sku, type: String
      end
    end
  end

  it "keeps the element TYPE message unpunctuated" do
    expect(action.call(rows: ["nope"]).exception.message).to include("element at index 0 is not a Hash")
  end

  it "keeps the element MEMBER message colon-prefixed" do
    expect(action.call(rows: [{ sku: 1 }]).exception.message).to include("element at index 0: sku is not a String")
  end

  # THE one message this canonicalization moves, and it moves the flat spelling onto the nested one's
  # answer. Before it, the shape's container was `Array` — the whole ARRAY, which matched — so the members
  # were read off every element whatever its class, and a String element reported "sku could not be read"
  # BESIDE the type error. After it the shape sits at the element position and gates on the element's own
  # class, exactly as a hand-written `of: { klass: Hash, shape: … }` always has: one error, naming the one
  # thing to fix. Probed on both trees; `of: { klass: Hash, shape: … }` reported the type error alone before
  # this change too, so what converged is the pair of spellings rather than the rule.
  it "reports the element TYPE error alone when the element is the wrong type" do
    message = action.call(rows: ["nope"]).exception.message
    expect(message).to include("element at index 0 is not a Hash")
    expect(message).not_to include("could not be read")
  end

  # The class-unconstrained spelling has no type to report, so its members are still read off whatever
  # arrived — the ANY_CONTAINER sentinel is what keeps that true after the fold.
  it "still reports an unreadable member where the bag gates on nothing" do
    action = build_axn do
      expects :rows, type: Array do
        field :sku, type: String
      end
    end

    expect(action.call(rows: ["nope"]).exception.message).to include("element at index 0: sku could not be read")
  end
end

# The block form and the bag it canonicalizes a raw distributing shape into are ONE contract after
# canonicalization, so every bound has to charge them alike. The depth budget is where that is load-bearing
# rather than tidy: a value walked against either spelling spends two rungs per link — `OfValidator` descends
# the container to the element, then `ShapeValidator` descends the element to its members — so a declaration
# walk that charged the block spelling one rung per link would accept a chain that raises `ArgumentError: a
# shape: graph nests more than 64 levels deep` on every call.
RSpec.describe "the block form and the bag it canonicalizes into share every bound" do
  def member(field, validations) = Axn::Core::Contract::ShapeConfig.new(field:, validations:)

  def leaf = { members: [member(:leaf, { type: { klass: String } })] }

  # `type: Array` + a distributing block, chained — a raw `shape:` kwarg naming the same distributing
  # structure is refused outright (PRO-3191), so a block is the only remaining spelling to compare the bag
  # against.
  def block_chain(depth)
    return proc { field :leaf, type: String } if depth.zero?

    inner = block_chain(depth - 1)
    proc { field :"m#{depth}", type: Array, &inner }
  end

  # The same contract written the way canonicalization stores it.
  def bagged(depth)
    return leaf if depth.zero?

    { members: [member(:"m#{depth}", { type: { klass: Array }, of: { klass: Hash, shape: bagged(depth - 1) } })] }
  end

  def of_chain(depth) = depth.zero? ? Integer : { klass: Array, of: of_chain(depth - 1) }

  def array_chain(depth) = depth.zero? ? 1 : [array_chain(depth - 1)]

  def value(depth)
    return { leaf: "x" } if depth.zero?

    { "m#{depth}": [value(depth - 1)] }
  end

  def declarable_block?(depth)
    chain = block_chain(depth)
    build_axn { expects(:payload, type: Hash, &chain) }
    true
  rescue ArgumentError
    false
  end

  def declarable?(shape)
    build_axn { expects :payload, type: Hash, shape: }
    true
  rescue ArgumentError
    false
  end

  def deepest_declarable_block
    (1..Axn::Internal::ShapeGraph::MAX_NESTING).find { |d| !declarable_block?(d) } - 1
  end

  def deepest_declarable(builder)
    (1..Axn::Internal::ShapeGraph::MAX_NESTING).find { |d| !declarable?(builder.call(d)) } - 1
  end

  it "refuses the flat spelling this bag canonicalizes, at any nesting depth" do
    flat = { members: [member(:m3, { type: { klass: Array }, shape: { members: [member(:m2, { type: { klass: Array }, shape: leaf })] } })] }

    expect { build_axn { expects :payload, type: Hash, shape: flat } }
      .to raise_error(ArgumentError, /`shape:` on shape member `m3` distributes over an Array's elements/)
  end

  it "declares to exactly the same depth via a block chain as via the bag it canonicalizes into" do
    block_depth = deepest_declarable_block
    expect(block_depth).to eq(deepest_declarable(method(:bagged)))
    # Two rungs per link — the `of:` rung and the shape node below it — so half the budget, stated as
    # arithmetic rather than a literal so a change to it is a deliberate one rather than a drifting number.
    expect(block_depth).to eq(Axn::Internal::ShapeGraph::MAX_NESTING / 2)
  end

  # The runtime half, at a depth the validator's per-link cost can actually reach — the walk is exponential in
  # the number of links, which is why this pins agreement rather than the cap itself.
  it "validates identically via a block chain as via the bag it canonicalizes into" do
    chain = block_chain(6)
    bag_shape = bagged(6)
    block_action = build_axn { expects(:payload, type: Hash, &chain) }
    bag_action = build_axn { expects :payload, type: Hash, shape: bag_shape }

    [block_action, bag_action].each do |action|
      expect(action.call(payload: value(6))).to be_ok
      corrupted = value(6)
      corrupted[:m6][0][:m5][0][:m4][0][:m3][0][:m2][0][:m1] = [{ leaf: 1 }]
      expect(action.call(payload: corrupted).exception.message).to include("leaf is not a String")
    end
  end
  # A graph EXACTLY at the cap declares and then validates — the pairing the whole depth offset exists to keep
  # true. Reached along an `of:` chain rather than a chain of distributing shapes, because the runtime shape
  # walk is exponential in the number of shape links (measured: ~2.3s at 24) while an `of:` chain is linear:
  # this construction spends the field's `of:` rung, the folded shape node and then 62 `of:` rungs, which is
  # the cap, and it costs milliseconds. The pair is what pins it — drop the fold's rung and the "refuses" side
  # moves, charge it twice and the "validates" side does.
  it "declares AND validates a folded graph that lands exactly on the cap" do
    at_cap = of_chain(Axn::Internal::ShapeGraph::MAX_NESTING - 2)
    one_deeper = of_chain(Axn::Internal::ShapeGraph::MAX_NESTING - 1)
    action = build_axn { expects(:rows, type: Array) { field :m, type: Array, of: at_cap } }

    expect(action.call(rows: [{ m: array_chain(Axn::Internal::ShapeGraph::MAX_NESTING - 1) }])).to be_ok
    expect { build_axn { expects(:rows, type: Array) { field :m, type: Array, of: one_deeper } } }
      .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
  end

  # The memo-hit re-judge names the edge the reused subtree's own deepest rung sits on, not the edge the
  # reference reached it by. A shape reused at a deep position is walked once and judged again wherever it is
  # used, with only its recorded height left to judge by — so a shape whose height is an `of:` chain used to be
  # reported as a `shape:` graph and told to flatten a nesting it does not have.
  it "attributes a reused subtree's depth to the edge that supplies it" do
    of_chain = ->(n) { n.zero? ? Integer : { klass: Array, of: of_chain.call(n - 1) } }
    shared = { members: [member(:x, { type: { klass: Array }, of: of_chain.call(3) })] }
    deep = ->(d) { d.zero? ? shared : { members: [member(:"m#{d}", { type: { klass: Hash }, shape: deep.call(d - 1) })] } }

    # Walked (and memoized) at a shallow position first; the deep reference is the re-judge.
    outer = { container: Hash, members: [
      member(:s, { type: { klass: Hash }, shape: shared }),
      member(:d, { type: { klass: Hash }, shape: deep.call(Axn::Internal::ShapeGraph::MAX_NESTING - 4) }),
    ] }

    expect { build_axn { expects :payload, type: Hash, shape: outer } }
      .to raise_error(ArgumentError, /an `of:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
  end

  # A REUSED member shape, judged again by its recorded height at the memo-hit above, exposes whether the
  # one-rung member-shape cost is actually charged rather than assumed. There is no distributing counterpart
  # to this test: a distributing member shape can no longer be reused by IDENTITY at all — the raw `shape:`
  # spelling that could name one is refused (PRO-3191), and a block always builds a fresh Hash per
  # declaration site, so no two positions can ever share the same object.
  describe "a member's own nested shape, reused deep enough for the memo to matter" do
    def wrap(depth, shared)
      return shared if depth.zero?

      { members: [member(:"w#{depth}", { type: { klass: Hash }, shape: wrap(depth - 1, shared) })] }
    end

    def reused(depth, shared)
      { container: Hash, members: [
        member(:s, { type: { klass: Hash }, shape: shared }),
        member(:d, { type: { klass: Hash }, shape: wrap(depth, shared) }),
      ] }
    end

    it "does not charge a reused NON-distributing member shape a second rung" do
      shared = { members: [member(:x, { type: { klass: Hash }, shape: leaf })] }
      at_cap = reused(Axn::Internal::ShapeGraph::MAX_NESTING - 2, shared)

      expect { build_axn { expects :payload, type: Hash, shape: at_cap } }.not_to raise_error
    end
  end

  # The memo-hit re-judge above only ever exercises an `of:`-sourced height (see the two tests before it, and
  # the one above this). A shape reused with no `of:` anywhere in it — pure shape-in-shape nesting — has to
  # attribute its own too-deep message to `shape:` rather than default (or invert) to `of:`.
  it "attributes a reused PURE-shape subtree's depth to shape:, not of:" do
    shape_chain = ->(n) { n.zero? ? leaf : { members: [member(:"c#{n}", { type: { klass: Hash }, shape: shape_chain.call(n - 1) })] } }
    shared = shape_chain.call(3)
    deep = ->(d) { d.zero? ? shared : { members: [member(:"m#{d}", { type: { klass: Hash }, shape: deep.call(d - 1) })] } }

    outer = { container: Hash, members: [
      member(:s, { type: { klass: Hash }, shape: shared }),
      member(:d, { type: { klass: Hash }, shape: deep.call(Axn::Internal::ShapeGraph::MAX_NESTING - 3) }),
    ] }

    expect { build_axn { expects :payload, type: Hash, shape: outer } }
      .to raise_error(ArgumentError, /a `shape:` graph nested more than #{Axn::Internal::ShapeGraph::MAX_NESTING} levels deep/)
  end
end
