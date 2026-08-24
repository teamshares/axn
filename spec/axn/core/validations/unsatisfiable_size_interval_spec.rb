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

  # `presence:` and `absence:` are exact complements at EVERY type — no value is blank and not blank — so this
  # needs no size reasoning, and is the only rule here that does not.
  describe "absence: against the presence check axn infers" do
    [Array, Hash, String, Integer].each do |klass|
      it "refuses absence: true on a #{klass} field" do
        expect { declare(type: klass, absence: true) }
          .to raise_error(ArgumentError, /presence: and absence:.*admit no value at all/m)
      end
    end

    it "refuses absence: true on an untyped field, where the inferred check is the whole other half" do
      expect { declare(absence: true) }
        .to raise_error(ArgumentError, /presence: and absence:.*admit no value at all/m)
    end

    it "refuses an authored presence: true beside it" do
      expect { declare(type: Array, presence: true, absence: true) }
        .to raise_error(ArgumentError, /presence: and absence:.*admit no value at all/m)
    end

    it "names the flag that suppresses the check axn infers" do
      expect { declare(type: Array, absence: true) }
        .to raise_error(ArgumentError, /`allow_empty: true` \(or `presence: false`\)/)
    end

    # The one place a gate rescues rather than being counted static-maximally: the gated pair has a reading the
    # ungated pair has not, and no structural test tells complementary conditions from identical ones.
    it "stands down where either half carries its own gate" do
      expect { declare(type: Array, presence: { unless: -> { false } }, absence: { if: -> { false } }) }
        .not_to raise_error
    end

    # A DECLARATION-level gate skips both checks together, so on every call where it is closed the field
    # accepts anything — the same legitimate reading, reached by a different spelling. What matters here is
    # whether both checks run on every call, which is a question about EFFECTIVE gates rather than about the
    # gate each entry owns.
    %i[if unless].each do |key|
      it "stands down under a declaration-level `#{key}:`, which skips both halves together" do
        expect { declare(type: Array, presence: true, absence: true, key => -> { false }) }.not_to raise_error
      end
    end

    it "stands down where a declaration-level gate reaches an otherwise bare absence:" do
      expect { declare(type: Array, absence: true, if: -> { false }) }.not_to raise_error
    end

    # A declaration gate is weighed THROUGH each entry rather than as a fact of its own, which is what keeps
    # ActiveModel's per-key precedence intact: a blank nested `if:` drops the shared gate for that key, leaving
    # the entry ungated after all — so both checks run on every call and the pair admits nothing.
    it "still refuses where a blank nested gate drops the shared one" do
      expect { declare(type: Array, presence: { if: nil }, absence: { if: nil }, if: -> { false }) }
        .to raise_error(ArgumentError, /presence: and absence:.*admit no value at all/m)
    end

    # A presence entry being PRESENT is not it rejecting anything: blank values are the only ones it ever
    # rejects, and a blank-tolerant entry is skipped for exactly those — so it leaves `absence:` unopposed.
    it "stands down where the presence half is blank-tolerant, and so enforces nothing" do
      action = declare(type: Array, presence: { allow_blank: true }, absence: true)

      expect(action.call(f: []).ok?).to be(true)
      expect(action.call(f: ["a"]).ok?).to be(false)
    end

    it "leaves the gated pair working at runtime" do
      action = declare(type: Array, presence: { unless: :archived }, absence: { if: :archived })
      action.define_method(:archived) { false }

      expect(action.call(f: ["a"]).ok?).to be(true)
    end

    # The derived ceiling needs an unconditional check, so a gated absence names none — and the contract really
    # is satisfiable on every call where the gate is closed.
    it "declares a GATED absence: on an Array, and emits no ceiling for it" do
      action = declare(type: Array, absence: { if: -> { false } })

      expect(action.call(f: ["a"]).ok?).to be(true)
      expect(action.input_schema[:properties][:f]).not_to have_key(:maxItems)
    end

    # ActiveSupport gives String its own `blank?`: `"  "` is blank and two characters long. So `absence:` there
    # bounds whitespace rather than size, and nothing may read a size bound out of it — this contract really is
    # satisfiable, by any whitespace-only String.
    it "declares a String contract whose only admissible values are whitespace" do
      action = declare(type: String, presence: false, absence: true, length: { minimum: 1 })

      expect(action.call(f: "  ").ok?).to be(true)
      expect(action.call(f: "").ok?).to be(false)
      expect(action.call(f: "x").ok?).to be(false)
    end

    it "emits no size ceiling for a String absence:, which names no size" do
      prop = declare(type: String, absence: true, allow_empty: true).input_schema[:properties][:f]

      expect(prop).not_to have_key(:maxLength)
    end

    it "emits no ceiling for an absence: a declaration-level gate can skip" do
      prop = declare(type: Array, absence: true, allow_empty: true, if: -> { false }).input_schema[:properties][:f]

      expect(prop).not_to have_key(:maxItems)
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

    it "names correcting the bounds rather than dropping a floor the author did not write" do
      expect { declare(type: Array, length: { minimum: 3, maximum: 2 }) }
        .to raise_error(ArgumentError, /Correct the bounds so the floor does not sit above the ceiling/)
    end

    it "offers allow_empty: where the emptiness axis is the floor" do
      expect { declare(type: Array, length: { maximum: 0 }) }
        .to raise_error(ArgumentError, /drop the floor with `allow_empty: true`/)
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

    # A blank value skips a blank-tolerant entry outright, so the set stops being the only way through and the
    # member scan proves nothing — but only where such a value can actually arrive, which is a question about
    # the rest of the contract.
    describe "a blank-tolerant entry, which a blank value skips entirely" do
      it "stands down where no floor keeps the blank value out" do
        action = declare(type: Array, presence: false, length: { maximum: 1 },
                         inclusion: { in: [%w[a b c]], allow_blank: true })

        expect(action.call(f: []).ok?).to be(true)
      end

      # An entry's own tolerance does not carry the FIELD: here the presence check still rejects the `[]` the
      # tolerance would have let past, so nothing gets through and the refusal stands.
      it "still refuses where the floor rejects the blank value anyway" do
        expect { declare(type: Array, inclusion: { in: [[]], allow_blank: true }) }
          .to raise_error(ArgumentError, /can never match/)
      end

      # For a String a blank value has very nearly any size, so once the emptiness axis is off no SIZE bound
      # rules one out — a floor of 2 still admits `"  "`.
      it "stands down for a String past a floor, since a blank String is not an empty one" do
        action = declare(type: String, presence: false, length: { minimum: 2, maximum: 2 },
                         inclusion: { in: %w[abcd], allow_blank: true })

        expect(action.call(f: "  ").ok?).to be(true)
      end

      # A live presence check rejects every blank value whatever its size, so on a String too there is then no
      # blank value to bypass the set with, and the refusal stands.
      it "still refuses a String where the presence check rejects every blank value" do
        expect { declare(type: String, inclusion: { in: [""], allow_blank: true }) }
          .to raise_error(ArgumentError, /can never match/)
      end

      it "reads a declaration-level allow_blank: the same way" do
        action = declare(type: Array, presence: false, length: { maximum: 1 },
                         inclusion: { in: [%w[a b c]] }, allow_blank: true)

        expect(action.call(f: []).ok?).to be(true)
      end
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
      let(:overriding_blank) { Class.new(Array) { def blank? = false } }

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

      # The third route: the floor here is the presence check, which asks the value `blank?`. A member
      # answering that with its own code clears the floor at runtime whatever its length says.
      it "stands down on a member that answers `blank?` with its own code" do
        expect { declare(type: Array, inclusion: { in: [overriding_blank.new] }) }.not_to raise_error
      end

      it "accepts at runtime the member whose blank? it stood down on" do
        member = overriding_blank.new
        action = declare(type: Array, inclusion: { in: [member] })

        expect(action.call(f: member).ok?).to be(true)
      end

      # `Array#include?` dispatches `member == candidate`, so a member's own `==` decides what it matches —
      # and measuring the member is evidence about those values only where its equality is one axn vouches
      # for. That world is closed and asked by EXACT class, so every subclass stands the branch down.
      it "stands down on a member whose == decides membership for itself" do
        member = Class.new(Array) { def ==(other) = other == [1] }.new

        expect { declare(type: Array, length: { minimum: 1 }, inclusion: { in: [member] }) }.not_to raise_error
      end

      it "accepts at runtime the value that member matches" do
        member = Class.new(Array) { def ==(other) = other == [1] }.new
        action = declare(type: Array, length: { minimum: 1 }, inclusion: { in: [member] })

        expect(action.call(f: [1]).ok?).to be(true)
      end

      # Exact class says nothing about a SINGLETON method — which cuts both ways: the member's `==` is read
      # through the same ownership test as its measurement, because an exact `Array` whose equality is its own
      # decides membership for itself.
      it "stands down on a plain Array carrying a singleton ==" do
        member = []
        def member.==(other) = other == [1]

        expect { declare(type: Array, length: { minimum: 1 }, inclusion: { in: [member] }) }.not_to raise_error
      end

      it "accepts at runtime the value that singleton == matches" do
        member = []
        def member.==(other) = other == [1]
        action = declare(type: Array, length: { minimum: 1 }, inclusion: { in: [member] })

        expect(action.call(f: [1]).ok?).to be(true)
      end

      it "stands down on a plain Array carrying a singleton length" do
        member = []
        def member.length = 3

        expect { declare(type: Array, length: { minimum: 3 }, inclusion: { in: [member] }) }.not_to raise_error
      end

      # `Object#blank?` is ActiveSupport's own, and answers out of the `empty?` already required native — so a
      # Set, whose `blank?` AS does not specialize, stays measurable rather than standing the guard down.
      it "measures a Set, whose blank? is ActiveSupport's generic one" do
        expect { declare(type: Set, inclusion: { in: [Set.new] }) }
          .to raise_error(ArgumentError, /can never match/)
      end

      # A SUBCLASS stands the branch down whether or not it overrides anything: `JUDGEABLE_EQUALITY_CLASSES`
      # is asked by exact class precisely because a subclass's equality — overridden or inherited across the
      # boundary — is not the one axn vouches for. Under-restricting here is the direction the closed world
      # was built to err in.
      it "stands down on a subclass that overrides nothing" do
        expect { declare(type: Array, inclusion: { in: [Class.new(Array).new] }) }.not_to raise_error
      end

      it "still refuses the exact-class member the ticket is about" do
        expect { declare(type: Array, inclusion: { in: [[]] }) }
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
