# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "bigdecimal" # non-Rails specs don't autoload it
require "date"

# The vacuity and satisfiability guards judge a literal by TYPE MEMBERSHIP — can a value of the declared type
# equal this literal, or be a member of this set. That misses a second way a literal can match nothing: being
# DEGENERATE — a bound that cannot equal itself, or a set that names nothing at all, whatever its type. Every
# such literal is of the declared type, so a membership reading sees a legitimate witness and stands down.
#
# Two degenerate shapes, and the runtime truth behind each is measured rather than reasoned:
#
#   * a NaN bound. Every one of ActiveModel's five non-inverted operators reports false against it
#     (`x == NAN`, `x > NAN`, `x >= NAN`, `x < NAN`, `x <= NAN` — all false for every x, NaN included), so the
#     check rejects every value; its one inverted operator `!=` reports true against it, so that check passes
#     always. Same property, opposite verdict.
#   * an empty Range. It covers nothing, so `inclusion:` rejects every value and `exclusion:` forbids none.
#     Emptiness is a property of the Range alone, so unlike a Range's BOUNDS it needs no container position to
#     be judged at.
RSpec.describe "a degenerate literal" do
  # A Comparable value object whose operators accept another class — the shape the closed equality world exists
  # to stand down on, and the reason a bound's reflexivity cannot be judged at every declared type.
  let(:money) do
    Class.new do
      include Comparable
      def self.name = "Money"
      attr_reader :cents

      def initialize(cents) = (@cents = cents)
      def <=>(other) = cents <=> (other.respond_to?(:cents) ? other.cents : other)
      def ==(other) = (self <=> other)&.zero? || false
    end
  end

  describe "a bound nothing can equal, not even itself" do
    it "refuses every non-inverted operator carrying a NaN bound, which rejects every value" do
      %i[equal_to greater_than greater_than_or_equal_to less_than less_than_or_equal_to].each do |operator|
        expect { build_axn { expects :n, type: Float, comparison: { operator => Float::NAN } } }
          .to raise_error(ArgumentError, /comparison:.*can never match/m),
              "expected #{operator}: Float::NAN to be refused"
      end
    end

    it "refuses the inverted operator on the opposite verdict — it enforces nothing" do
      expect { build_axn { expects :n, type: Float, comparison: { other_than: Float::NAN } } }
        .to raise_error(ArgumentError, /comparison:.*enforces nothing/m)
    end

    it "judges a BigDecimal NaN, whichever side of the comparison carries it" do
      # `BigDecimal::NAN != BigDecimal::NAN` exactly as Float's does, and the declared type does not have to be
      # BigDecimal for the bound to be the degenerate half.
      expect { build_axn { expects :n, type: BigDecimal, comparison: { equal_to: BigDecimal::NAN } } }
        .to raise_error(ArgumentError, /comparison:.*can never match/m)
      expect { build_axn { expects :n, type: BigDecimal, comparison: { other_than: BigDecimal::NAN } } }
        .to raise_error(ArgumentError, /comparison:.*enforces nothing/m)
      expect { build_axn { expects :n, type: Float, comparison: { other_than: BigDecimal::NAN } } }
        .to raise_error(ArgumentError, /comparison:.*enforces nothing/m)
      expect { build_axn { expects :n, type: Integer, comparison: { other_than: BigDecimal::NAN } } }
        .to raise_error(ArgumentError, /comparison:.*enforces nothing/m)
    end

    it "leaves an ordinary BigDecimal bound alone, and it still enforces" do
      action = build_axn { expects :n, type: BigDecimal, comparison: { other_than: BigDecimal("1") } }

      expect(action.call(n: BigDecimal("1")).ok?).to be(false)
      expect(action.call(n: BigDecimal("2")).ok?).to be(true)
    end

    it "stands down on a declared type whose equality axn has not vouched for" do
      # `Money#==` answers for the bound, so a Money really can differ from NaN and the check really does have
      # a failing input. Judging the bound's reflexivity here would refuse a contract that enforces.
      klass = money
      expect { build_axn { expects :n, type: klass, comparison: { other_than: Float::NAN } } }.not_to raise_error
      expect { build_axn { expects :n, type: klass, comparison: { equal_to: Float::NAN } } }.not_to raise_error
    end

    it "stands down on a bound carrying its own equality rather than its class's" do
      # A per-object override generalizes one object's behaviour to every value of the declared type, and runs
      # the caller's own code to do it. Decided by ownership, so a singleton method never answers.
      bound = String.new("x") # a frozen literal takes no singleton method
      bound.define_singleton_method(:!=) { |_other| true }
      bound.define_singleton_method(:==) { |_other| false }

      action = build_axn { expects :s, type: String, comparison: { other_than: bound } }

      expect(action.call(s: "x").ok?).to be(false) # an ordinary String really does fail the check
      expect(action.call(s: "y").ok?).to be(true)
    end

    it "leaves a SET containing NaN alone, because membership short-circuits on identity" do
      # `[Float::NAN].include?(Float::NAN)` and `Set[Float::NAN].include?(Float::NAN)` are both true — the
      # collection compares object identity before it ever asks `==` — so the set really does forbid the value.
      nan = Float::NAN
      action = build_axn { expects :n, type: Float, exclusion: { in: [nan] } }

      expect(action.call(n: nan).ok?).to be(false)
      expect(action.call(n: 1.0).ok?).to be(true)
    end
  end

  describe "`equal_to:` judged at every declared type, as its inverted twin already is" do
    it "refuses a wrong-typed equality bound at a scalar position" do
      expect { build_axn { expects :s, type: String, comparison: { equal_to: 1 } } }
        .to raise_error(ArgumentError, /comparison:.*can never match/m)
      expect { build_axn { expects :n, type: Integer, comparison: { equal_to: "x" } } }
        .to raise_error(ArgumentError, /comparison:.*can never match/m)
      expect { build_axn { expects :d, type: Date, comparison: { equal_to: 0 } } }
        .to raise_error(ArgumentError, /comparison:.*can never match/m)
    end

    it "keeps the four `<=>` operators judged only at a container position" do
      # `Date > 0` is TRUE — Ruby reads a Numeric bound as an Astronomical Julian Day Number — so this
      # declaration genuinely works, and judging it by equality's closed world would refuse it. `==` has no
      # such hole, which is what makes ungating `equal_to:` safe while these four stay gated.
      action = build_axn { expects :d, type: Date, comparison: { greater_than: 0 } }

      expect(action.call(d: Date.new(2020, 1, 1)).ok?).to be(true)
    end

    it "still admits an equality bound that crosses within a comparable family" do
      action = build_axn { expects :n, type: Float, comparison: { equal_to: 1 } }

      expect(action.call(n: 1.0).ok?).to be(true)
      expect(action.call(n: 2.0).ok?).to be(false)
    end

    it "stands down on a declared type whose equality axn has not vouched for" do
      klass = money
      expect { build_axn { expects :n, type: klass, comparison: { equal_to: 0 } } }.not_to raise_error
    end
  end

  describe "a blank value the entry's own tolerance skips" do
    it "stands the satisfiability guard down where that blank is admitted and passes" do
      # `presence: false` admits the blank, and the entry's `allow_blank:` makes ActiveModel skip it before the
      # check runs — so a value passes and the contract enforces something. Refusing it claims "every value is
      # rejected", which the blank disproves.
      action = build_axn { expects :v, type: Array, presence: false, inclusion: { in: [1], allow_blank: true } }

      expect(action.call(v: []).ok?).to be(true)
      expect(action.call(v: ["a"]).ok?).to be(false)
    end

    it "does the same for a comparison bound, at a scalar position and a container one" do
      scalar = build_axn { expects :v, type: String, presence: false, comparison: { equal_to: 1, allow_blank: true } }
      expect(scalar.call(v: "").ok?).to be(true)
      expect(scalar.call(v: "a").ok?).to be(false)

      container = build_axn { expects :v, type: Array, presence: false, comparison: { equal_to: 1, allow_blank: true } }
      expect(container.call(v: []).ok?).to be(true)
      expect(container.call(v: ["a"]).ok?).to be(false)
    end

    it "keeps refusing where the blank is rejected anyway, so nothing passes after all" do
      # The default presence check is still in place, so `[]` is rejected by presence while every non-empty
      # Array fails inclusion — the entry's tolerance exempts only the entry.
      expect { build_axn { expects :v, type: Array, inclusion: { in: ["a"], allow_blank: true } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :v, type: Array, comparison: { equal_to: 1, allow_blank: true } } }
        .to raise_error(ArgumentError, /comparison:/)

      # `allow_empty: false` installs its own check on the same axis, so the blank is rejected there too.
      expect do
        build_axn { expects :v, type: Array, allow_empty: false, inclusion: { in: [1], allow_blank: true } }
      end.to raise_error(ArgumentError, /inclusion:/)
    end

    it "keeps refusing on a type with no blank instance at all" do
      expect { build_axn { expects :v, type: Integer, presence: false, comparison: { equal_to: "x", allow_blank: true } } }
        .to raise_error(ArgumentError, /comparison:.*can never match/m)
    end
  end

  describe "an empty Range names nothing, at any position" do
    it "refuses an exclusion set that forbids no value" do
      expect { build_axn { expects :n, type: Integer, exclusion: { in: (1...1) } } }
        .to raise_error(ArgumentError, /exclusion:.*enforces nothing/m)
      expect { build_axn { expects :n, type: Integer, exclusion: { in: (2..1) } } }
        .to raise_error(ArgumentError, /exclusion:.*enforces nothing/m)
      expect { build_axn { expects :n, type: Float, exclusion: { in: (1.0...1.0) } } }
        .to raise_error(ArgumentError, /exclusion:.*enforces nothing/m)
    end

    it "refuses an inclusion set that admits no value" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: (1...1) } } }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
      expect { build_axn { expects :n, type: Integer, inclusion: { in: (2..1) } } }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
      expect { build_axn { expects :n, type: Float, inclusion: { in: (2.0..1.0) } } }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
    end

    it "judges a Date/Time-bounded Range, which Clusivity also decides with cover?" do
      day = Date.new(2020, 1, 1)
      expect { build_axn { expects :d, type: Date, inclusion: { in: (day...day) } } }
        .to raise_error(ArgumentError, /inclusion:.*can never match/m)
      expect { build_axn { expects :d, type: Date, exclusion: { in: (day...day) } } }
        .to raise_error(ArgumentError, /exclusion:.*enforces nothing/m)
    end

    it "names the empty Range in the message rather than blaming the literals' type" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: (1...1) } } }
        .to raise_error(ArgumentError, /empty/)
    end

    it "leaves a non-empty Range alone, and it still enforces" do
      action = build_axn { expects :n, type: Integer, inclusion: { in: (1..2) } }

      expect(action.call(n: 1).ok?).to be(true)
      expect(action.call(n: 3).ok?).to be(false)

      single = build_axn { expects :n, type: Integer, exclusion: { in: (1..1) } }
      expect(single.call(n: 1).ok?).to be(false)
      expect(single.call(n: 2).ok?).to be(true)
    end

    it "leaves a one-sided Range alone, which is never empty" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: (1..) } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, inclusion: { in: (..1) } } }.not_to raise_error
    end

    it "stands down on a reversed INCLUSIVE String Range, which genuinely enforces" do
      # Measured, and the reason emptiness is judged only where Clusivity decides membership with `cover?`:
      # `("b".."a").include?("a")` is TRUE — Ruby's single-character String shortcut answers for the `end`
      # whatever the order — so this contract really does reject a value, while `cover?` reports it empty.
      action = build_axn { expects :s, type: String, inclusion: { in: ("b".."a") } }

      expect(action.call(s: "a").ok?).to be(true)
      expect(action.call(s: "b").ok?).to be(false)
    end

    it "stands down on a Range of the declared container, which raises loudly on every call" do
      # Clusivity picks iteration-based `include?` for a Range whose begin is not Numeric/Time, and
      # `(["a"]...["a"]).include?([])` raises TypeError. Standing down leaves that behaviour exactly as it is.
      expect { build_axn { expects :tags, type: Array, exclusion: { in: (["a"]...["a"]) } } }.not_to raise_error
    end

    it "stands down on a Range subclass, which may decide membership its own way" do
      subclass = Class.new(Range)
      empty = subclass.new(1, 1, true)

      expect { build_axn { expects :n, type: Integer, exclusion: { in: empty } } }.not_to raise_error
    end
  end
end
