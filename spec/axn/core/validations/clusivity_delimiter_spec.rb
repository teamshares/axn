# frozen_string_literal: true

require "axn/testing/spec_helpers"

# ActiveModel's `Clusivity#check_validity!` accepts a delimiter answering `include?`, `call`, or `to_sym` — but
# axn only reaches that code the first time the validator class is compiled (`ValidatorClassCache`, on the
# first `.call`), so a delimiter it cannot use used to declare cleanly and raise ActiveModel's own opaque
# `ArgumentError` on EVERY call instead of one naming the field at the point it was declared. Two causes:
#
# * A BARE delimiter that is not a Range or an Array is routed by ActiveModel's own `_parse_validates_options`
#   to `{ with: … }`, which `Clusivity#delimiter` never reads (`options[:in] || options[:within]`) — so a bare
#   Proc, Symbol, Set subclass, or unusable value all raised regardless of whether the long form would have
#   worked. Everything ActiveModel COULD use is now canonicalized into the long form instead (PRO-3319 already
#   did this for a bare Set/Hash; this extends it to every other bare shape).
# * A LONG form naming a delimiter ActiveModel cannot use at all (`{ in: 5 }`), or naming none (`{ in: nil }`,
#   `{}`), reached `check_validity!` with nothing usable and raised the same way.
#
# The verdict is ActiveModel's own: the declaration builds the validator it will compile to, which runs
# `check_validity!` exactly as `validates` does in a model's class body. Past that, two shapes ActiveModel
# cannot see are refused too: an `include?`/`call` that cannot take the one argument ActiveModel passes it, and
# a String, whose `include?` is a SUBSTRING test that raises `TypeError` for any value that is not a String.
#
# `acceptance:` was audited for the same hole and has none: `AcceptanceValidator` carries no `check_validity!`
# at all and reads its set through `Array()`, so `accept: 5`/`accept: "abc"`/`accept: nil` all declare and
# validate without raising (measured).
RSpec.describe "a clusivity delimiter ActiveModel cannot use is refused at declaration" do
  member_struct = Struct.new(:field, :validations)
  my_set = Class.new(Set)

  # `outcome` distinguishes a genuine rejection from a declaration-time raise, so a test cannot pass by trading
  # one failure mode for the other (mirrors `clusivity_set_canonicalization_spec.rb`'s own classifier).
  def outcome(result)
    return :pass if result.ok?

    exception = result.exception
    exception.nil? || exception.is_a?(Axn::InboundValidationError) ? :reject : :raise
  end

  # Every position a clusivity entry can be declared at — the field path's seven from
  # `clusivity_set_canonicalization_spec.rb`, plus the two more `invalid_length_bounds_spec.rb` covers for the
  # identical declares-cleanly-then-raises shape (`exposes`, `Axn::Factory.build`).
  positions = {
    "top-level field (expects)" => ->(key, entry) { build_axn { expects(:v, **{ key => entry }) } },
    "exposes" => ->(key, entry) { build_axn { exposes(:v, **{ key => entry }) } },
    "subfield" => lambda { |key, entry|
      build_axn do
        expects :par, type: Hash
        expects(:v, on: :par, **{ key => entry })
      end
    },
    "shape member (block form)" => lambda { |key, entry|
      build_axn { expects(:par, type: Hash) { field(:v, **{ key => entry }) } }
    },
    "shape member (raw bag)" => lambda { |key, entry|
      members = [member_struct.new(:v, { key => entry })]
      build_axn { expects :par, type: Hash, shape: { members: } }
    },
    "of: element bag" => lambda { |key, entry|
      build_axn { expects :par, type: Array, of: { klass: Numeric, **{ key => entry } } }
    },
    "of: values: axis" => lambda { |key, entry|
      build_axn { expects :par, type: Hash, of: { values: { klass: Numeric, **{ key => entry } } } }
    },
    "of: keys: axis" => lambda { |key, entry|
      build_axn do
        expects :par, type: Hash, of: { keys: { klass: Numeric, **{ key => entry } }, values: { klass: Numeric } }
      end
    },
    "Axn::Factory.build" => ->(key, entry) { Axn::Factory.build(expects: { v: { key => entry } }) { nil } },
  }

  describe "at every declared position" do
    positions.each do |position, declare|
      # `declare` is a lambda literal defined at the describe body's own scope, so its `self` is fixed at
      # DEFINITION time (a lambda, unlike a block, never rebinds `self` to its caller) — `instance_exec` is
      # what runs it against the example instance instead, which is what makes `build_axn` reachable.
      it "refuses the sharpest repro (a bare Integer) at a #{position}" do
        expect { instance_exec(:inclusion, 5, &declare) }.to raise_error(ArgumentError, /inclusion: on .* names a set/)
      end

      it "still declares the ordinary Array spelling at a #{position}" do
        expect { instance_exec(:inclusion, [1, 2], &declare) }.not_to raise_error
      end
    end
  end

  describe "delimiters ActiveModel cannot use at all, refused at a top-level field" do
    {
      "a bare Integer" => 5,
      "a bare true" => true,
      "the long form naming an Integer" => { in: 5 },
      "the long form naming an Integer via within:" => { within: 5 },
      "the long form naming a plain Object" => { in: Object.new },
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, inclusion: spelling } }
          .to raise_error(ArgumentError, /inclusion: on :v names a set of class \w+, which ActiveModel cannot use/)
      end
    end

    it "names the class of the offending value and quotes ActiveModel's own error" do
      expect { build_axn { expects :v, inclusion: 5 } }
        .to raise_error(ArgumentError, /class Integer.*An object with the method #include\? or a proc, lambda or symbol is required/)
    end

    # A bare Hash is ALWAYS read as the long-form options bag (`ShapeGraph.hash_or_nil` matches any Hash), so
    # `inclusion: { 1 => :x }` is never "a Hash used as a membership set" — that needs the explicit long form,
    # `inclusion: { in: { 1 => :x } }`. Written bare, it names neither `in:` nor `within:` and falls into the
    # "no delimiter at all" case below; documented here since it looks like a set literal at a glance.
    it "reads a bare Hash as the options bag, not as a Hash-keyed set — refused as naming no delimiter" do
      expect { build_axn { expects :v, inclusion: { 1 => :x } } }
        .to raise_error(ArgumentError, /inclusion: on :v names no set at all/)
    end
  end

  # `check_validity!` asks only whether `include?`/`call` EXIST. `WholeValueClusivity#include?` then calls
  # `members.public_send(:include?, value)` and `resolve_value` calls a non-Proc callable as `call(record)` —
  # exactly one argument each — so a signature that cannot take it declares cleanly and raises
  # `ArgumentError: wrong number of arguments` on every call.
  describe "a delimiter whose include?/call cannot take the argument ActiveModel passes it" do
    it "refuses an include? taking no arguments" do
      stub_const("ZeroArgInclude", Class.new { def include? = true })

      expect { build_axn { expects :v, inclusion: ZeroArgInclude.new.freeze } }
        .to raise_error(ArgumentError, /names a set of class ZeroArgInclude, which ActiveModel cannot use — its `include\?` cannot take/)
    end

    it "refuses an include? whose required params a trailing splat cannot excuse" do
      stub_const("RestButRequiredInclude", Class.new { def include?(_first, _second, *_rest) = true })

      expect { build_axn { expects :v, inclusion: RestButRequiredInclude.new.freeze } }
        .to raise_error(ArgumentError, /names a set of class RestButRequiredInclude, which ActiveModel cannot use/)
    end

    it "refuses a callable object whose call takes no record" do
      stub_const("ZeroArgCall", Class.new { def call = [1, 2, 3] })

      expect { build_axn { expects :v, inclusion: ZeroArgCall.new.freeze } }
        .to raise_error(ArgumentError, /names a set of class ZeroArgCall, which ActiveModel cannot use — its `call` cannot take/)
    end

    # `Method#call` is always `(*args)`; the signature that decides is the bound target's.
    it "refuses a Method whose bound target requires two arguments" do
      stub_const("MethodDelimiterHelper", Class.new { def self.allowed(_record, _second) = [1, 2, 3] })

      expect { build_axn { expects :v, inclusion: MethodDelimiterHelper.method(:allowed) } }
        .to raise_error(ArgumentError, /names a set of class Method, which ActiveModel cannot use/)
    end

    it "refuses a lambda requiring two arguments, since resolve_value passes at most the record" do
      expect { build_axn { expects :v, inclusion: ->(_record, _second) { [1, 2, 3] } } }
        .to raise_error(ArgumentError, /names a set of class Proc, which ActiveModel cannot use — its `call` cannot take the 1 argument/)
    end

    it "refuses a lambda requiring a keyword" do
      expect { build_axn { expects :v, inclusion: ->(_record, only:) { [only] } } }
        .to raise_error(ArgumentError, /names a set of class Proc, which ActiveModel cannot use/)
    end

    # `resolve_value` calls a zero-arity Proc with no arguments, and a non-lambda Proc pads or drops
    # positional arguments on its own.
    {
      "a zero-arity lambda" => -> { [1, 2, 3] },
      "a one-arity lambda" => ->(_record) { [1, 2, 3] },
      "a lambda with an optional second argument" => ->(_record, _second = nil) { [1, 2, 3] },
      "a non-lambda proc naming two arguments" => proc { |_record, _second| [1, 2, 3] },
    }.each do |label, delimiter|
      it "declares and enforces #{label}" do
        action = build_axn { expects :v, inclusion: delimiter }

        expect(outcome(action.call(v: 1))).to eq(:pass)
        expect(outcome(action.call(v: 5))).to eq(:reject)
      end
    end

    it "declares and enforces a Method whose bound target takes the record" do
      stub_const("MethodDelimiterTarget", Class.new { def self.allowed(_record) = [1, 2, 3] })

      action = build_axn { expects :v, inclusion: MethodDelimiterTarget.method(:allowed) }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end
  end

  describe "a long form naming no delimiter at all" do
    {
      "an empty bag" => {},
      "only message:" => { message: "x" },
      "a falsy in:, nothing else" => { in: nil },
      "a falsy within:, nothing else" => { within: false },
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, inclusion: spelling } }
          .to raise_error(ArgumentError, /inclusion: on :v names no set at all/)
      end
    end

    it "reads in:/within: by ActiveModel's own truthiness precedence, not by key presence" do
      # `in:` is present but falsy, so ActiveModel falls through to `within:` — a real set — and the
      # declaration must read the SAME winner rather than reporting "no set at all".
      expect { build_axn { expects :v, inclusion: { in: nil, within: [1] } } }.not_to raise_error
    end
  end

  describe "a String delimiter, refused even though it answers include?" do
    it "is refused as the bare shorthand" do
      expect { build_axn { expects :v, inclusion: "abc" } }
        .to raise_error(ArgumentError, /inclusion: on :v names a String as its set/)
    end

    it "is refused in the long form" do
      expect { build_axn { expects :v, inclusion: { in: "abc" } } }
        .to raise_error(ArgumentError, /names a String as its set \(of class String\)/)
    end

    it "names the substring/TypeError reason and both remedies" do
      expect { build_axn { expects :v, inclusion: { in: "abc" } } }
        .to raise_error(ArgumentError, /SUBSTRING.*%w\[a b c\].*format:/m)
    end

    it "does not refuse a String SUBCLASS that overrides include? with its own membership test" do
      overridden = Class.new(String) { def include?(other) = other == :always }
      set = overridden.new("irrelevant").freeze

      expect { build_axn { expects :v, inclusion: { in: set } } }.not_to raise_error
    end
  end

  describe "a Range delimiter" do
    it "declares and enforces an unmodified Range subclass, numeric or string bounded" do
      stub_const("PlainRangeSubclass", Class.new(Range))

      numeric_action = build_axn { expects :v, inclusion: { in: PlainRangeSubclass.new(1, 10) } }
      expect(outcome(numeric_action.call(v: 5))).to eq(:pass)
      expect(outcome(numeric_action.call(v: 20))).to eq(:reject)

      string_action = build_axn { expects :v, inclusion: { in: PlainRangeSubclass.new("a", "z") } }
      expect(outcome(string_action.call(v: "m"))).to eq(:pass)
      expect(outcome(string_action.call(v: "zz"))).to eq(:reject)
    end
  end

  # A Set SUBCLASS, or any other object answering `include?`, is stored as the declaration's OWN membership set
  # — by reference. A caller who still holds it could mutate it after declaring, changing an already-declared
  # class's membership retroactively, so it must be frozen. An Array needs no freeze because the option
  # detachment copies it, and a Range because its bounds cannot change.
  describe "a mutable delimiter — must be frozen, or aliasing could change membership after declaring" do
    it "refuses an unfrozen bare Set SUBCLASS" do
      stub_const("MutableSet", Class.new(Set))

      expect { build_axn { expects :v, inclusion: MutableSet[1, 2] } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class MutableSet that is not frozen/)
    end

    it "refuses an unfrozen custom object answering include?" do
      stub_const("MutableMembership", Class.new { def include?(_value) = true })

      expect { build_axn { expects :v, inclusion: { in: MutableMembership.new } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class MutableMembership that is not frozen/)
    end

    it "accepts a frozen bare Set SUBCLASS and its membership cannot change after declaring" do
      stub_const("FrozenMutableSet", Class.new(Set))
      allowed = FrozenMutableSet[1, 2].freeze

      action = build_axn { expects :v, inclusion: allowed }

      expect(outcome(action.call(v: 3))).to eq(:reject)
      expect { allowed.add(3) }.to raise_error(FrozenError)
    end

    it "does not require an Array or Range to be frozen, and mutating the caller's Array changes nothing" do
      allowed = [1, 2]
      action = build_axn { expects :v, inclusion: allowed }
      allowed << 3
      expect(outcome(action.call(v: 3))).to eq(:reject)

      subclass_allowed = Class.new(Array).new([1, 2])
      subclass_action = build_axn { expects :v, inclusion: { in: subclass_allowed } }
      subclass_allowed << 3
      expect(outcome(subclass_action.call(v: 3))).to eq(:reject)

      expect { build_axn { expects :v, inclusion: 1..10 } }.not_to raise_error
      expect { build_axn { expects :v, inclusion: { in: Class.new(Range).new(1, 10) } } }.not_to raise_error
    end

    # A Set with code of its own is not read out into its members, so it is judged like any other
    # `include?`-answering object — the arity refusal included.
    it "refuses a frozen Set SUBCLASS whose singleton include? cannot accept the value ActiveModel always supplies" do
      stub_const("ZeroArgIncludeSet", Class.new(Set))
      broken = ZeroArgIncludeSet[1, 2, 3]
      def broken.include? = true
      broken.freeze

      expect { build_axn { expects :v, inclusion: broken } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgIncludeSet, which ActiveModel cannot use/)
    end

    it "does not require an unfrozen Proc or callable to be frozen, since what it compares against is decided per call" do
      stub_const("MutableCallable", Class.new { def call(_record) = [1, 2, 3] })

      action = build_axn { expects :v, inclusion: ->(_record) { [1, 2, 3] } }
      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)

      expect { build_axn { expects :v, inclusion: MutableCallable.new } }.not_to raise_error
    end
  end

  describe "the exclusion mirror" do
    it "refuses an unusable delimiter the same way inclusion does" do
      expect { build_axn { expects :v, exclusion: 5 } }
        .to raise_error(ArgumentError, /exclusion: on :v names a set of class Integer/)
    end

    it "refuses a String delimiter the same way inclusion does" do
      expect { build_axn { expects :v, exclusion: "abc" } }
        .to raise_error(ArgumentError, /exclusion: on :v names a String as its set/)
    end

    it "refuses a wrong-arity lambda the same way inclusion does" do
      expect { build_axn { expects :v, exclusion: ->(_record, _second) { [1] } } }
        .to raise_error(ArgumentError, /exclusion: on :v names a set of class Proc, which ActiveModel cannot use/)
    end
  end

  # The bare-shorthand hole was wider than what raised an ActiveModel error the ticket quoted: a bare Proc and
  # a bare Symbol are legal delimiters in the long form and used to raise on every call in the bare one too.
  describe "bare delimiters that now WORK instead of raising on every call" do
    {
      "a bare Proc" => ->(_record) { [1] },
      "a bare Symbol naming an action method" => :allowed_values,
      "a bare Set subclass" => my_set[1].freeze,
    }.each do |label, entry|
      it "declares and enforces #{label}, at a top-level field" do
        action = build_axn do
          expects :v, inclusion: entry
          define_method(:allowed_values) { [1] }
        end

        expect(outcome(action.call(v: 1))).to eq(:pass)
        expect(outcome(action.call(v: 2))).to eq(:reject)
      end

      it "declares and enforces #{label}, inside an of: bag" do
        action = build_axn do
          expects :par, type: Array, of: { klass: Numeric, inclusion: entry }
          define_method(:allowed_values) { [1] }
        end

        expect(outcome(action.call(par: [1]))).to eq(:pass)
        expect(outcome(action.call(par: [2]))).to eq(:reject)
      end
    end
  end

  describe "accepted delimiters (controls — must still declare cleanly)" do
    {
      "bare Array" => [1],
      "bare Range" => 1..5,
      "bare Set" => Set[1],
      "bare Set subclass" => my_set[1].freeze,
      "bare Proc" => ->(_r) { [1] },
      "bare Symbol" => :allowed,
      # The method may be defined later in the class body, so an unknown name is not refused.
      "bare Symbol naming no method yet" => :nope,
      "long form naming an Array" => { in: [1] },
      "long form naming a Range" => { in: 1..5 },
      "long form naming a Set subclass" => { in: my_set[1].freeze },
      "long form naming a plain object answering include?" => { in: Class.new { def include?(_value) = true }.new.freeze },
      "a disabled (falsy) entry" => false,
      "a nil entry" => nil,
    }.each do |label, spelling|
      it "declares cleanly for #{label}" do
        expect { build_axn { expects :v, inclusion: spelling } }.not_to raise_error
      end
    end
  end
end
