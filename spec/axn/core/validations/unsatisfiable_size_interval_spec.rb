# frozen_string_literal: true

require "axn/testing/spec_helpers"

# The corollary in AGENTS.md: the projection of a satisfiable contract must itself be satisfiable. These
# declarations violate it from the other side — the CONTRACT admits nothing, so there is no honest node to
# emit. Every one of them is the same shape: the sizes the declaration admits form an EMPTY interval, because
# a floor it imposes sits above a ceiling it also imposes. See
# internal-docs/agent-notes/guards-and-projections.md.
RSpec.describe "a declaration whose admissible sizes form an empty interval" do
  def declare(**opts)
    build_axn { expects :f, **opts }
  end

  describe "absence: against the non-emptiness floor a typed field carries" do
    [Array, Hash, String].each do |klass|
      it "refuses absence: true on a #{klass} field" do
        expect { declare(type: klass, absence: true) }
          .to raise_error(ArgumentError, /admits no value at all/)
      end
    end

    # `absence:` names a ceiling of 0 wherever the value has a size or not: the floor comes from the presence
    # check axn infers, and presence and absence are exact complements.
    it "refuses absence: true on an untyped field, where the inferred presence check is the whole floor" do
      expect { declare(absence: true) }.to raise_error(ArgumentError, /admits no value at all/)
    end

    it "refuses absence: true on an Integer field, whose type rejects the only blank an absence admits" do
      expect { declare(type: Integer, absence: true) }.to raise_error(ArgumentError, /admits no value at all/)
    end

    it "names both bounds and the spelling that produced the ceiling" do
      expect { declare(type: Array, absence: true) }
        .to raise_error(ArgumentError, /at least 1.*at most 0 \(from `absence:`\)/m)
    end

    # The remedy tracks which side the floor came from: `allow_empty:` moves the emptiness floor and nothing
    # else, so offering it against a floor the author spelled in `length:` would send them the wrong way.
    it "offers allow_empty: only where the emptiness axis is the floor" do
      expect { declare(type: Array, absence: true) }.to raise_error(ArgumentError, /drop the floor with `allow_empty: true`/)
      expect { declare(type: Array, length: { minimum: 3, maximum: 2 }) }
        .to raise_error(ArgumentError, /Correct the bounds so the floor does not sit above the ceiling/)
    end

    # A gate removes the check rather than giving it a reading, and reflection is static-maximal — so a gated
    # absence still emits the `maxItems: 0` that collides with the floor. Same policy the value-constraint
    # guard states for a gated `inclusion:`.
    it "refuses a GATED absence:, which still emits its ceiling" do
      expect { declare(type: Array, absence: { if: -> { false } }) }
        .to raise_error(ArgumentError, /admits no value at all/)
    end

    it "leaves absence: false alone — a disabled validator constrains nothing" do
      action = declare(type: Array, absence: false)
      expect(action.call(f: ["a"]).ok?).to be(true)
    end

    it "leaves :boolean alone, which takes no inferred presence check and so has no floor" do
      action = declare(type: :boolean, absence: true)
      expect(action.call(f: false).ok?).to be(true)
    end
  end

  describe "a zero ceiling against the same floor" do
    { "a maximum of 0" => { maximum: 0 }, "an exact length of 0" => { is: 0 } }.each do |label, length|
      it "refuses #{label} on an Array field" do
        expect { declare(type: Array, length:) }.to raise_error(ArgumentError, /admits no value at all/)
      end
    end
  end

  describe "a floor above its own ceiling, inside one length: entry" do
    it "refuses minimum: 3 alongside maximum: 2" do
      expect { declare(type: Array, length: { minimum: 3, maximum: 2 }) }
        .to raise_error(ArgumentError, /admits no value at all/)
    end

    it "refuses it on a String field too — the shape is not container-only" do
      expect { declare(type: String, length: { minimum: 3, maximum: 2 }) }
        .to raise_error(ArgumentError, /admits no value at all/)
    end

    # Neither bound comes from the emptiness axis here, so nothing about emptiness rescues it.
    it "refuses it with allow_empty: true, which moves neither bound" do
      expect { declare(type: Array, length: { minimum: 3, maximum: 2 }, allow_empty: true) }
        .to raise_error(ArgumentError, /admits no value at all/)
    end

    # ActiveModel's own implicit floor counts as one of the two bounds: a blank-intolerant entry picks up
    # `minimum: 1` (activemodel length.rb:22), which the shared reader carries, so the pair contradicts inside
    # one entry without either bound being spelled out.
    it "refuses a zero ceiling against the floor a blank-intolerant entry picks up" do
      expect { declare(type: Array, length: { maximum: 0, allow_blank: false }) }
        .to raise_error(ArgumentError, /admits no value at all/)
    end

    it "leaves a floor that meets its ceiling alone" do
      action = declare(type: Array, length: { minimum: 2, maximum: 2 })
      expect(action.call(f: %w[a b]).ok?).to be(true)
    end

    it "stands down on a per-call bound, which nothing here can read" do
      action = declare(type: Array, length: { minimum: :cap, maximum: 2 })
      expect(action).to be_a(Class)
    end
  end

  describe "an inclusion set whose every member is outside the admitted sizes" do
    it "refuses a set holding only the empty container the floor forbids" do
      expect { declare(type: Array, inclusion: { in: [[]] }) }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
    end

    it "refuses it on a Hash and a String field alike" do
      expect { declare(type: Hash, inclusion: { in: [{}] }) }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
      expect { declare(type: String, inclusion: { in: [""] }) }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
    end

    # The floor need not be the emptiness one: any floor above every member's size closes the set the same way.
    it "refuses a set whose members are all below a declared floor" do
      expect { declare(type: Array, length: { minimum: 3 }, inclusion: { in: [[1]] }) }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
    end

    it "refuses a set whose members are all above a declared ceiling" do
      expect { declare(type: Array, length: { maximum: 1 }, inclusion: { in: [[1, 2], [3, 4, 5]] }) }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
    end

    it "leaves a set with one size-admissible member alone" do
      action = declare(type: Array, inclusion: { in: [[], [1]] })
      expect(action.call(f: [1]).ok?).to be(true)
      expect(action.call(f: []).ok?).to be(false)
    end

    # A member of the wrong type can never rescue a set: it fails the type check whatever its size.
    it "refuses a set whose only non-empty member is of the wrong type" do
      expect { declare(type: Array, inclusion: { in: [[], "x"] }) }
        .to raise_error(ArgumentError, /can never match/)
    end

    it "stands down on a set it may not read" do
      action = declare(type: Array, inclusion: { in: :allowed_tags })
      expect(action).to be_a(Class)
    end

    # Two routes enforce the size bounds and they measure by different methods — `length:` reads
    # `value.length` (activemodel 8.1.3.1, length.rb:48), the emptiness axis asks `empty?` — so a member is
    # weighed only where both are Ruby's own. A container that answers one of them with code of its own is a
    # member this guard cannot place, and standing down leaves the declaration legal.
    describe "a member whose measurement is not Ruby's own" do
      let(:overriding_length) { Class.new(Array) { def length = 3 } }
      let(:overriding_empty) { Class.new(Array) { def empty? = false } }

      it "stands down on a member that answers `length` with its own code" do
        member = overriding_length.new

        expect { declare(type: Array, presence: false, length: { minimum: 3 }, inclusion: { in: [member] }) }
          .not_to raise_error
      end

      # The control: the runtime really does accept that member, so refusing the declaration above would
      # reject a contract that works.
      it "accepts at runtime the member it stood down on" do
        member = overriding_length.new
        action = declare(type: Array, presence: false, length: { minimum: 3 }, inclusion: { in: [member] })

        expect(action.call(f: member).ok?).to be(true)
      end

      it "stands down on a member that answers `empty?` with its own code" do
        expect { declare(type: Array, inclusion: { in: [overriding_empty.new] }) }.not_to raise_error
      end

      # A subclass that overrides NEITHER is measured by the built-in it inherits, so the refusal still lands.
      it "still refuses a subclass that overrides neither" do
        expect { declare(type: Array, inclusion: { in: [Class.new(Array).new] }) }
          .to raise_error(ArgumentError, /can never match/)
      end
    end
  end

  # A tolerated nil is a passing value, and it makes the emitted node satisfiable through its null branch —
  # the same stand-down the value-constraint guard makes, for the same reason.
  describe "a nil tolerance rescues every one of them" do
    [
      { absence: true },
      { length: { maximum: 0 } },
      { length: { minimum: 3, maximum: 2 } },
      { inclusion: { in: [[]] } },
    ].each do |opts|
      it "declares #{opts.inspect} under optional:" do
        action = declare(type: Array, optional: true, **opts)
        expect(action.call.ok?).to be(true)
      end

      it "declares #{opts.inspect} under allow_nil:" do
        expect { declare(type: Array, allow_nil: true, **opts) }.not_to raise_error
      end
    end
  end

  # Dropping the floor is the other resolution, and it leaves a contract that really does admit exactly one
  # value — which is what the emitted ceiling then says.
  describe "dropping the floor leaves a satisfiable contract" do
    it "admits the empty container under allow_empty: true" do
      action = declare(type: Array, absence: true, allow_empty: true)

      expect(action.call(f: []).ok?).to be(true)
      expect(action.call(f: ["a"]).ok?).to be(false)
    end

    it "admits it under presence: false as well" do
      action = declare(type: Array, presence: false, length: { maximum: 0 })
      expect(action.call(f: []).ok?).to be(true)
    end
  end
end
