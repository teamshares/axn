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
# A String is refused even though it answers `include?` (so `check_validity!` itself declares it clean): its
# `include?` is a SUBSTRING test and raises `TypeError` for any value that is not itself a String, which is the
# identical declares-cleanly-then-raises shape one level past ActiveModel's own check.
#
# `acceptance:` was audited for the same hole and has none: `AcceptanceValidator` carries no `check_validity!`
# at all and reads its set through `Array()`, so `accept: 5`/`accept: "abc"`/`accept: nil` all declare and
# validate without raising (measured).
RSpec.describe "a clusivity delimiter ActiveModel cannot use is refused at declaration" do
  member_struct = Struct.new(:field, :validations)
  my_set = Class.new(Set)

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
    }.each do |label, spelling|
      it "refuses #{label}" do
        expect { build_axn { expects :v, inclusion: spelling } }
          .to raise_error(ArgumentError, /inclusion: on :v names a set of class \w+, which ActiveModel cannot use/)
      end
    end

    it "names the class of the offending value, not its inspected content" do
      expect { build_axn { expects :v, inclusion: 5 } }.to raise_error(ArgumentError, /class Integer/)
    end

    # A bare Hash is ALWAYS read as the long-form options bag (`ShapeGraph.hash_or_nil` matches any Hash), so
    # `inclusion: { 1 => :x }` is never "a Hash used as a membership set" — that needs the explicit long form,
    # `inclusion: { in: { 1 => :x } }`. Written bare, it names neither `in:` nor `within:` and falls into the
    # "no delimiter at all" case below; documented here since it looks like a set literal at a glance.
    it "reads a bare Hash as the options bag, not as a Hash-keyed set — refused as naming no delimiter" do
      expect { build_axn { expects :v, inclusion: { 1 => :x } } }
        .to raise_error(ArgumentError, /inclusion: on :v names no set at all/)
    end

    # `check_validity!` accepts anything answering `respond_to?(:to_sym)`, but `resolve_value` only treats an
    # actual Symbol that way (`case value when Symbol`) — everything else falls through to
    # `value.include?(record_value)`. An object with a public `to_sym` that is not itself a Symbol clears that
    # check and then raises `NoMethodError` on every call, so it must be refused the same as any other unusable
    # delimiter, in both spellings.
    it "refuses an object answering only to_sym, which is not an actual Symbol" do
      stub_const("ToSymOnlyDelimiter", Class.new { def to_sym = :whatever })

      expect { build_axn { expects :v, inclusion: ToSymOnlyDelimiter.new } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ToSymOnlyDelimiter, which ActiveModel cannot use/)
      expect { build_axn { expects :v, inclusion: { in: ToSymOnlyDelimiter.new } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ToSymOnlyDelimiter, which ActiveModel cannot use/)
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
      set = overridden.new("irrelevant")

      expect { build_axn { expects :v, inclusion: { in: set } } }.not_to raise_error
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
  end

  # The bare-shorthand hole was wider than what raised an ActiveModel error the ticket quoted: a bare Proc and
  # a bare Symbol are legal delimiters in the long form and used to raise on every call in the bare one too.
  # `outcome` distinguishes a genuine rejection from the raise this fix removes, so a test cannot pass by
  # trading one failure mode for the other (mirrors `clusivity_set_canonicalization_spec.rb`'s own classifier).
  describe "bare delimiters that now WORK instead of raising on every call" do
    def outcome(result)
      return :pass if result.ok?

      exception = result.exception
      exception.nil? || exception.is_a?(Axn::InboundValidationError) ? :reject : :raise
    end

    {
      "a bare Proc" => ->(_record) { [1] },
      "a bare Symbol naming an action method" => :allowed_values,
      "a bare Set subclass" => my_set[1],
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
      "bare Set subclass" => my_set[1],
      "bare Proc" => ->(_r) { [1] },
      "bare Symbol" => :allowed,
      "long form naming an Array" => { in: [1] },
      "long form naming a Range" => { in: 1..5 },
      "long form naming a Set subclass" => { in: my_set[1] },
      "long form naming a plain object answering include?" => { in: Class.new { def include?(_value) = true }.new },
      "a disabled (falsy) entry" => false,
      "a nil entry" => nil,
    }.each do |label, spelling|
      it "declares cleanly for #{label}" do
        expect { build_axn { expects :v, inclusion: spelling } }.not_to raise_error
      end
    end
  end

  # The guard mirrors `check_validity!` by OWNERSHIP (a method-table lookup), never by dispatching
  # `respond_to?`/`is_a?`/`inspect` on the caller's own delimiter — the same rule
  # `certainly_resolved_per_call?` already follows in this file. Doubt must answer "usable": refusing an
  # undecidable delimiter would refuse a declaration ActiveModel might in fact accept.
  describe "ownership, not dispatch" do
    it "declares a delimiter reachable only through the caller's own method_missing (doubt permits)" do
      liar = Object.new
      def liar.method_missing(name, *) = name == :include? ? true : super
      def liar.respond_to_missing?(name, _include_private = false) = name == :include? || super

      expect { build_axn { expects :v, inclusion: { in: liar } } }.not_to raise_error
    end

    it "never calls the caller's own respond_to?/is_a?/inspect while judging or reporting an unusable delimiter" do
      dispatched = []
      hostile = Object.new
      hostile.define_singleton_method(:respond_to?) do |*a|
        dispatched << :respond_to?
        super(*a)
      end
      hostile.define_singleton_method(:is_a?) do |*a|
        dispatched << :is_a?
        super(*a)
      end
      hostile.define_singleton_method(:inspect) do
        dispatched << :inspect
        "HOSTILE"
      end

      expect { build_axn { expects :v, inclusion: { in: hostile } } }.to raise_error(ArgumentError) do |e|
        expect(e.message).not_to include("HOSTILE")
      end
      expect(dispatched).to eq([])
    end
  end
end
