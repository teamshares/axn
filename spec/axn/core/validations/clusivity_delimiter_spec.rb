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

  # `outcome` distinguishes a genuine rejection from a declaration-time raise, so a test cannot pass by trading
  # one failure mode for the other (mirrors `clusivity_set_canonicalization_spec.rb`'s own classifier). Shared
  # across every describe block below that enforces a delimiter end to end.
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

    # `check_validity!` probes the delimiter with `delimiter.respond_to?(:include?) || …`, and `respond_to?`
    # is an ordinary Kernel method — a value rooted at BasicObject with nothing added has none at all, so that
    # first probe raises `NoMethodError` regardless of what `include?` the object itself defines (Codex, PR
    # #288). A public `include?` alone is not enough to call a delimiter usable.
    it "refuses a BasicObject-rooted delimiter, which cannot even answer respond_to?" do
      stub_const("BasicObjectDelimiter", Class.new(BasicObject) { def include?(_value) = true })

      expect { build_axn { expects :v, inclusion: BasicObjectDelimiter.new } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class BasicObjectDelimiter, which ActiveModel cannot use/)
    end

    # A BasicObject subclass that DOES supply its own public `respond_to?` (answering false for everything)
    # is a different case from the one above: `respond_to_reachable?` passes, and every later ownership read
    # (`Identity.class_of`, `NativeMethods.method_owner`) still works fine on a BasicObject in current Ruby —
    # `Object.instance_method(:class).bind_call` does not require the receiver to be a `kind_of?` `Object`.
    # No crash, no permissive-rescue fallback; the guard reaches its ordinary `false` verdict directly.
    it "refuses a BasicObject-rooted delimiter with its own respond_to? that answers false for everything" do
      stub_const("BasicObjectFalseRespondTo", Class.new(BasicObject) { def respond_to?(_name, *) = false })

      expect { build_axn { expects :v, inclusion: BasicObjectFalseRespondTo.new } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class BasicObjectFalseRespondTo, which ActiveModel cannot use/)
    end

    # `check_validity!` calls `delimiter.respond_to?(...)` with an EXPLICIT receiver, so a `respond_to?` the
    # table finds but visibility narrows to private/protected is just as unreachable as one absent entirely —
    # `NoMethodError: private method 'respond_to?' called for ...` on the first call (Codex, PR #288).
    it "refuses a delimiter whose inherited respond_to? has been narrowed to private" do
      stub_const("PrivateRespondToDelimiter", Class.new do
        def include?(_value) = true
        private :respond_to?
      end)

      expect { build_axn { expects :v, inclusion: PrivateRespondToDelimiter.new } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class PrivateRespondToDelimiter, which ActiveModel cannot use/)
    end

    # `Clusivity#inclusion_method` calls `enumerable.is_a? Range` — an ordinary call with an explicit
    # receiver — for EVERY static delimiter, Range or not, before ever consulting `include?`/`cover?`. A
    # delimiter with a real public `include?` but an undefined `is_a?` (no `method_missing` to catch the
    # miss) still raises `NoMethodError` on the very first call (Codex, PR #288).
    it "refuses a non-Range delimiter whose is_a? has been undefined" do
      stub_const("NoIsADelimiter", Class.new do
        def include?(_value) = true
        undef_method :is_a?
      end)

      expect { build_axn { expects :v, inclusion: NoIsADelimiter.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class NoIsADelimiter, which ActiveModel cannot use/)
    end

    # `WholeValueClusivity#include?` performs the actual membership test as
    # `members.public_send(inclusion_method(members), value)` — an ordinary call with an explicit receiver,
    # for every static delimiter, Range or not. A delimiter with a real public `include?` but an undefined
    # `public_send` (no `method_missing` to catch the miss) still raises `NoMethodError` before `include?` is
    # ever reached (Codex, PR #288).
    it "refuses a non-Range delimiter whose public_send has been undefined" do
      stub_const("NoPublicSendDelimiter", Class.new do
        def include?(_value) = true
        undef_method :public_send
      end)

      expect { build_axn { expects :v, inclusion: NoPublicSendDelimiter.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class NoPublicSendDelimiter, which ActiveModel cannot use/)
    end

    # `WholeValueClusivity#include?` calls `members.public_send(:include?, value)` — ALWAYS with exactly one
    # positional argument, with no arity adaptation the way a Proc gets. A zero-arg `def include? = true` is
    # real, public, and answers `check_validity!`'s probe exactly as a correct one would, then raises
    # `ArgumentError: wrong number of arguments` on the very first real call (Codex, PR #288).
    it "refuses a delimiter whose include? cannot accept the one positional argument ActiveModel always supplies" do
      stub_const("ZeroArgInclude", Class.new { def include? = true })

      expect { build_axn { expects :v, inclusion: ZeroArgInclude.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgInclude, which ActiveModel cannot use/)
    end

    # `resolve_value`'s "else" branch (a real, public, non-Proc `call`) always calls `value.call(record)` —
    # ONE positional argument, unlike its Proc branch, which adapts to the Proc's own arity
    # (`value.arity == 0 ? value.call : value.call(record)`). A zero-arg `def call = [...]` is real and
    # public, so `certainly_resolved_per_call?` accepts it, and then the actual dispatch raises
    # `ArgumentError` before `include?` is ever reached (Codex, PR #288).
    it "refuses a delimiter whose call cannot accept the record argument ActiveModel always supplies" do
      stub_const("ZeroArgCall", Class.new { def call = [1, 2, 3] })

      expect { build_axn { expects :v, inclusion: ZeroArgCall.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgCall, which ActiveModel cannot use/)
    end

    # `check_validity!` probes with `delimiter.respond_to?(:include?)` — ONE positional argument, always. A
    # real, public, zero-arg `def respond_to? = true` answers indistinguishably from a correct one by every
    # ownership check (it IS public, it IS real), and then raises `ArgumentError` on that very first probe —
    # a real method always wins Ruby's dispatch over `method_missing` (Codex, PR #288).
    it "refuses a delimiter whose respond_to? cannot accept the one positional argument ActiveModel always supplies" do
      stub_const("ZeroArgRespondTo", Class.new do
        def respond_to? = true
        def include?(_value) = true
      end)

      expect { build_axn { expects :v, inclusion: ZeroArgRespondTo.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgRespondTo, which ActiveModel cannot use/)
    end

    # `Clusivity#inclusion_method` calls `enumerable.is_a? Range` — ONE positional argument, always. A real,
    # public, zero-arg `def is_a? = false` is certain `ArgumentError` on the first call, same precedence as
    # every other real-method-first case here (Codex, PR #288).
    it "refuses a delimiter whose is_a? cannot accept the one positional argument ActiveModel always supplies" do
      stub_const("ZeroArgIsA", Class.new do
        def is_a? = false
        def include?(_value) = true
      end)

      expect { build_axn { expects :v, inclusion: ZeroArgIsA.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgIsA, which ActiveModel cannot use/)
    end

    # `WholeValueClusivity#include?` calls `members.public_send(name, value)` — TWO positional arguments,
    # always. A real, public `public_send` accepting only one is certain `ArgumentError` before the verified
    # `include?` is ever reached (Codex, PR #288).
    it "refuses a delimiter whose public_send cannot accept the two positional arguments ActiveModel always supplies" do
      stub_const("OneArgPublicSend", Class.new do
        def include?(_value) = true
        def public_send(name) = name
      end)

      expect { build_axn { expects :v, inclusion: OneArgPublicSend.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class OneArgPublicSend, which ActiveModel cannot use/)
    end

    # `method_missing` is invoked as `method_missing(missed_name, *original_args)` — when `respond_to?`
    # itself is unreachable, that's `method_missing(:respond_to?, :include?)`, TWO args. A `method_missing`
    # accepting fewer (missing the conventional `*args` splat) raises `ArgumentError` on that very dispatch,
    # before the hook ever gets a chance to answer the probe (Codex, PR #288).
    it "refuses a delimiter whose respond_to?-catching method_missing cannot accept the two arguments ActiveModel always supplies" do
      stub_const("ZeroArgMethodMissing", Class.new do
        def include?(_value) = true

        def respond_to?(*) = super
        private :respond_to?

        # rubocop:disable Style/MissingRespondToMissing -- the missing arity is the point of this fixture
        def method_missing = true
        # rubocop:enable Style/MissingRespondToMissing
      end)

      expect { build_axn { expects :v, inclusion: ZeroArgMethodMissing.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgMethodMissing, which ActiveModel cannot use/)
    end

    # A real, native (untouched) `respond_to?` internally dispatches `respond_to_missing?(name, false)` — TWO
    # args — for any name absent from the table. A caller-owned `respond_to_missing?` with the wrong arity
    # (missing the conventional `(name, include_all = false)` signature) is real, public, and answers every
    # ownership check, then breaks `check_validity!`'s very first `respond_to?(:include?)` probe with
    # `ArgumentError` (Codex, PR #288).
    it "refuses a delimiter whose respond_to_missing? cannot accept the two arguments native respond_to? always supplies" do
      stub_const("ZeroArgRespondToMissing", Class.new do
        def respond_to_missing? = true

        def method_missing(name, *args)
          return [1, 2, 3] if name == :call

          super
        end
      end)

      expect { build_axn { expects :v, inclusion: ZeroArgRespondToMissing.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgRespondToMissing, which ActiveModel cannot use/)
    end

    # `check_validity!`'s gate short-circuits: `respond_to?(:include?)` answers the FIRST term on its own
    # once a real `include?` exists, and native `respond_to?` never falls through to `respond_to_missing?`
    # for a name already present in the table. A delimiter with working `include?` AND `call` methods, but a
    # broken `respond_to_missing?` that is never actually consulted, still declares and enforces fine (Codex,
    # PR #288: "requiring that hook to accept two arguments over-counts an unreachable path").
    it "declares and enforces a delimiter whose broken respond_to_missing? is never reached, since a real include? answers the probe first" do
      stub_const("RealIncludeAndCall", Class.new do
        def include?(value) = [1, 2, 3].include?(value)
        def call(_record) = [1, 2, 3]

        def respond_to_missing? = true
      end)

      action = build_axn { expects :v, inclusion: { in: RealIncludeAndCall.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end

    # A real `include?` alone answers `check_validity!`'s OWN gate without ever touching `respond_to_missing?`
    # — but `resolve_value`'s "else" branch separately asks `value.respond_to?(:call)`, UNCONDITIONALLY,
    # before `inclusion_method` is ever reached. With no real `call`, THAT probe reaches the broken hook all
    # the same, regardless of `include?`'s own realness (Codex, PR #288: "validate respond_to_missing? for
    # that later probe when native respond_to? will reach it").
    it "refuses a delimiter with a real include? but no real call, whose broken respond_to_missing? is reached by resolve_value's own probe" do
      stub_const("RealIncludeOnlyBadRespondToMissing", Class.new do
        def include?(value) = [1, 2, 3].include?(value)

        def respond_to_missing? = true

        def method_missing(name, *args)
          return [1, 2, 3] if name == :call

          super
        end
      end)

      expect { build_axn { expects :v, inclusion: RealIncludeOnlyBadRespondToMissing.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class RealIncludeOnlyBadRespondToMissing, which ActiveModel cannot use/)
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

    # `resolve_value`'s `else` branch checks `respond_to?(:call)` BEFORE anything ever reaches `include?`, so a
    # String subclass carrying a public `call` (returning the real collection) is resolved through that `call`
    # and its inherited substring `include?` is never invoked at all — refusing it would refuse a declaration
    # ActiveModel and the runtime both accept (Codex, PR #288).
    it "does not refuse a String SUBCLASS resolved per call, and enforces the resolved collection" do
      callable = Class.new(String) { def call(_record) = %w[a b] }

      action = build_axn { expects :v, inclusion: callable.new("irrelevant") }

      expect(outcome(action.call(v: "a"))).to eq(:pass)
      expect(outcome(action.call(v: "z"))).to eq(:reject)
    end

    it "still refuses a String SUBCLASS whose call is not public" do
      private_callable = Class.new(String) { private def call(_record) = %w[a b] }

      expect { build_axn { expects :v, inclusion: private_callable.new("irrelevant") } }
        .to raise_error(ArgumentError, /inclusion: on :v names a String as its set/)
    end
  end

  # `Clusivity#inclusion_method` selects `cover?` instead of `include?` for a Range bounded by
  # `Numeric`/`Time`/`DateTime`/`Date`, and dispatches whichever it picks with `public_send`. A real public
  # `include?` is therefore not enough for a Range on its own — `cover?` must be too, and vice versa, since
  # axn cannot know which one a given bound needs without dispatching `.begin`/`.end` on the caller's object
  # (Codex, PR #288, both directions).
  # `include?` is required UNCONDITIONALLY: `check_validity!`'s `respond_to?(:include?) || …` gate never asks
  # about `cover?` at all, so a private `include?` fails it regardless of the Range's bound. `cover?` is an
  # ADDITIONAL requirement ON TOP of `include?`, and only for a bound `Clusivity#inclusion_method` actually
  # selects it for (`Numeric`/`Time`/`DateTime`/`Date`) — never a substitute for `include?`, and never required
  # at all for a bound that doesn't select it (Codex, PR #288, corrected across two rounds).
  describe "a Range delimiter — include? is always required, cover? only when the bound selects it" do
    it "refuses a numeric-bounded Range SUBCLASS whose cover? has been undefined" do
      stub_const("NoCoverRange", Class.new(Range) { undef_method :cover? })

      expect { build_axn { expects :v, inclusion: { in: NoCoverRange.new(1, 10) } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class NoCoverRange, which ActiveModel cannot use/)
    end

    it "does not refuse a STRING-bounded Range SUBCLASS whose cover? has been undefined, since cover? is never touched" do
      stub_const("NoCoverStringRange", Class.new(Range) { undef_method :cover? })

      action = build_axn { expects :v, inclusion: { in: NoCoverStringRange.new("a", "z") } }

      expect(outcome(action.call(v: "m"))).to eq(:pass)
      expect(outcome(action.call(v: "zz"))).to eq(:reject)
    end

    it "refuses a Range SUBCLASS whose include? has been narrowed to private, regardless of bound or cover?" do
      stub_const("PrivateIncludeRange", Class.new(Range) { private :include? })
      stub_const("PrivateIncludeStringRange", Class.new(Range) { private :include? })

      expect { build_axn { expects :v, inclusion: { in: PrivateIncludeRange.new(1, 10) } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class PrivateIncludeRange, which ActiveModel cannot use/)
      expect { build_axn { expects :v, inclusion: { in: PrivateIncludeStringRange.new("a", "z") } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class PrivateIncludeStringRange, which ActiveModel cannot use/)
    end

    it "still declares and enforces an unmodified Range subclass, numeric or string bounded" do
      stub_const("PlainRangeSubclass", Class.new(Range))

      numeric_action = build_axn { expects :v, inclusion: { in: PlainRangeSubclass.new(1, 10) } }
      expect(outcome(numeric_action.call(v: 5))).to eq(:pass)
      expect(outcome(numeric_action.call(v: 20))).to eq(:reject)

      string_action = build_axn { expects :v, inclusion: { in: PlainRangeSubclass.new("a", "z") } }
      expect(outcome(string_action.call(v: "m"))).to eq(:pass)
      expect(outcome(string_action.call(v: "zz"))).to eq(:reject)
    end

    # `inclusion_method` calls `enumerable.begin`/`.end` NORMALLY (dispatched, reaching any override), so a
    # Range SUBCLASS whose overridden `begin` answers something other than its own native bound makes a
    # native-bound read diverge from what ActiveModel would actually see — this Range's STORED bound is
    # numeric, but `begin` is overridden to answer a String, so `inclusion_method` selects `include?` and
    # never touches the undefined `cover?` (Codex, PR #288).
    it "does not refuse a Range SUBCLASS whose begin is overridden and would select include?, even though its stored bound is numeric" do
      stub_const("OverriddenBeginRange", Class.new(Range) do
        undef_method :cover?
        def begin = "not-really-numeric"
      end)

      action = build_axn { expects :v, inclusion: { in: OverriddenBeginRange.new(1, 10).freeze } }

      # `inclusion_method` selects `include?` (since the overridden `begin` answers a String), so this
      # enforces via `(1..10).include?(v)` on the Range's REAL stored bound — never touching the undefined
      # `cover?`, which is the whole point: it must not raise.
      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end

    # `inclusion_method` calls `enumerable.begin` (and `.end` if `.begin` is falsy) with an EXPLICIT receiver,
    # so a Range SUBCLASS that narrows `begin` to private, with no `method_missing` to catch the miss, makes
    # that very first read raise `NoMethodError` — regardless of what `include?`/`cover?` look like. Distinct
    # from the overridden-value case above, where the call itself still succeeds (Codex, PR #288).
    it "refuses a Range SUBCLASS whose begin has been narrowed to private, with no method_missing to catch it" do
      stub_const("PrivateBeginRange", Class.new(Range) do
        undef_method :cover?
        private :begin
      end)

      expect { build_axn { expects :v, inclusion: { in: PrivateBeginRange.new(1, 10).freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class PrivateBeginRange, which ActiveModel cannot use/)
    end

    # Unlike `include?`/`call`/`to_sym`, `check_validity!` never probes `respond_to?(:cover?)` at all —
    # `cover?` only matters once `inclusion_method` has already selected it, and the actual dispatch
    # (`public_send`) reaches `method_missing` regardless of any `respond_to?` hook cooperating. So a Range
    # SUBCLASS that undefines `cover?` but handles it in `method_missing`, with no `respond_to_missing?`/
    # `respond_to?` override at all, still declares and enforces correctly (Codex, PR #288).
    it "declares and enforces a numeric-bounded Range SUBCLASS whose cover? is reached through method_missing" do
      stub_const("DynamicCoverRange", Class.new(Range) do
        undef_method :cover?
        # rubocop:disable Style/MissingRespondToMissing -- respond_to_missing? is irrelevant here: cover?'s
        # dispatch is an ordinary public_send, never gated behind respond_to?
        def method_missing(name, *args)
          return args.first >= self.begin && args.first <= self.end if name == :cover?

          super
        end
        # rubocop:enable Style/MissingRespondToMissing
      end)

      action = build_axn { expects :v, inclusion: { in: DynamicCoverRange.new(1, 10).freeze } }

      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end

    # `enumerable.begin || enumerable.end` is a genuine short-circuit: `.end` is asked at all only when
    # `.begin` answers falsy. So an untouched, numeric `begin` alone resolves the bound — an UNRELATED
    # override on `end` is never consulted and cannot make the resolution "unreliable" (Codex, PR #288).
    it "refuses a Range SUBCLASS whose reliable begin selects cover?, even though its unrelated end is overridden" do
      stub_const("OverriddenEndRange", Class.new(Range) do
        undef_method :cover?
        def end = "not-numeric"
      end)

      expect { build_axn { expects :v, inclusion: { in: OverriddenEndRange.new(1, 10).freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class OverriddenEndRange, which ActiveModel cannot use/)
    end

    # The mirror: `end` is never DISPATCHED at all when `begin` alone resolves the bound, so an unreachable
    # `end` (private/undefined, no `method_missing`) is irrelevant — refusing it here would refuse a
    # declaration ActiveModel and the runtime both accept (Codex, PR #288).
    it "does not refuse a Range SUBCLASS whose end is unreachable, since begin alone resolves the bound" do
      stub_const("UndefEndRange", Class.new(Range) { undef_method :end })

      action = build_axn { expects :v, inclusion: { in: UndefEndRange.new(1, 10).freeze } }

      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end

    # `inclusion_method` classifies its argument with `enumerable.is_a? Range` — a REAL, dispatched call, not
    # a question about ancestry. A Range subclass overriding it to answer `false` for `Range` makes
    # `inclusion_method` select `include?` and never touch `cover?` at all, so an undefined `cover?` is never
    # reached under real ActiveModel — even though the object's ANCESTRY still says Range (Codex, PR #288).
    it "does not refuse a numeric-bounded Range SUBCLASS whose is_a? is overridden to deny Range, even with cover? undefined" do
      stub_const("NotReallyARange", Class.new(Range) do
        undef_method :cover?
        def is_a?(klass) = klass.equal?(Range) ? false : super
      end)

      action = build_axn { expects :v, inclusion: { in: NotReallyARange.new(1, 10).freeze } }

      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end

    # `inclusion_method`'s `enumerable.is_a? Range` check happens BEFORE `cover?`/`include?` are ever
    # consulted, Range ancestry or not — so a Range SUBCLASS with `is_a?` undefined outright (not merely
    # overridden to answer `false`) raises on that very first call, regardless of what `include?`/`cover?`
    # look like (Codex, PR #288).
    it "refuses a Range SUBCLASS whose is_a? has been undefined outright" do
      stub_const("NoIsARange", Class.new(Range) { undef_method :is_a? })

      expect { build_axn { expects :v, inclusion: { in: NoIsARange.new(1, 10).freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class NoIsARange, which ActiveModel cannot use/)
    end

    # `WholeValueClusivity#include?` calls `members.public_send(:cover?, value)` with ONE positional
    # argument, same as `include?` — a real, public, zero-arg `def cover? = true` answers cleanly and then
    # raises `ArgumentError` on the very first numeric-bounded call. A real method always wins dispatch over
    # `method_missing`, so this is refused regardless of whatever `method_missing` might otherwise do (Codex,
    # PR #288).
    it "refuses a numeric-bounded Range SUBCLASS whose cover? cannot accept the one positional argument ActiveModel always supplies" do
      stub_const("ZeroArgCoverRange", Class.new(Range) { def cover? = true })

      expect { build_axn { expects :v, inclusion: { in: ZeroArgCoverRange.new(1, 10).freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgCoverRange, which ActiveModel cannot use/)
    end

    # `Clusivity#inclusion_method` calls `enumerable.begin` (and `.end`, only if `.begin` is falsy) with ZERO
    # arguments — a real override (by ANY owner, not necessarily maliciously) requiring one is certain
    # `ArgumentError` on that very first read, decidable from the method table alone regardless of whether
    # the override's VALUE would otherwise be trusted (Codex, PR #288).
    it "refuses a Range SUBCLASS whose begin requires an argument ActiveModel never supplies" do
      stub_const("ReqArgBeginRange", Class.new(Range) { def begin(val) = val })

      expect { build_axn { expects :v, inclusion: { in: ReqArgBeginRange.new(1, 10).freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ReqArgBeginRange, which ActiveModel cannot use/)
    end

    # `include?`'s own arity only matters when `inclusion_method` actually SELECTS it — never for a
    # numeric-bounded Range, where `cover?` is selected instead and `include?` is never dispatched at all. A
    # zero-arg `include?` alongside a correct `cover?` declares and enforces fine (Codex, PR #288: "the arity
    # requirement should apply only when include? is the selected membership method").
    it "does not refuse a numeric-bounded Range SUBCLASS whose include? cannot accept an argument, since cover? is selected instead" do
      stub_const("ZeroArgIncludeRange", Class.new(Range) { def include? = true })

      action = build_axn { expects :v, inclusion: { in: ZeroArgIncludeRange.new(1, 10).freeze } }

      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end

    # The mirror: a STRING-bounded Range selects `include?`, never `cover?`, so a zero-arg `include?` IS
    # certainly dispatched here and must be refused (Codex, PR #288).
    it "refuses a string-bounded Range SUBCLASS whose include? cannot accept an argument, since include? is certainly selected" do
      stub_const("ZeroArgIncludeStringRange", Class.new(Range) { def include? = true })

      expect { build_axn { expects :v, inclusion: { in: ZeroArgIncludeStringRange.new("a", "z").freeze } } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgIncludeStringRange, which ActiveModel cannot use/)
    end

    # `check_validity!`'s gate is `respond_to?(:include?) || respond_to?(:call) || respond_to?(:to_sym)` — a
    # real `to_sym` clears it on its own, with no real `include?` needed for VALIDITY. A numeric-bounded Range
    # whose `include?` is undefined still enforces fine, since `cover?` (untouched, inherited) is what
    # `inclusion_method` actually selects — `include?` is never dispatched at all (Codex, PR #288: "include?
    # is required for validity only when neither call nor to_sym can satisfy the validity gate").
    it "does not refuse a numeric-bounded Range SUBCLASS whose include? is undefined, since to_sym clears validity and cover? is selected" do
      stub_const("UndefIncludeToSymRange", Class.new(Range) do
        undef_method :include?
        def to_sym = :whatever
      end)

      action = build_axn { expects :v, inclusion: { in: UndefIncludeToSymRange.new(1, 10).freeze } }

      expect(outcome(action.call(v: 5))).to eq(:pass)
      expect(outcome(action.call(v: 20))).to eq(:reject)
    end
  end

  # `usable_clusivity_delimiter?` accepts a Set SUBCLASS, or any other object answering `include?`, and
  # `canonical_clusivity_entry` stores it as the declaration's OWN membership set — by reference. A caller who
  # still holds that object can mutate it after declaring, changing an already-declared class's membership
  # retroactively; `reject_unreadable_mutable_container!` already closes this for a Hash-keyed container, and
  # the SAME rule now applies to the wider bare-delimiter surface PRO-3326 opened (Codex, PR #288). Array and
  # Range are exempt: ActiveModel's own native bare-spelling routing already makes their aliasing a
  # pre-existing property, unrelated to and not introduced by this guard.
  describe "a mutable bare delimiter — must be frozen, or aliasing could change membership after declaring" do
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

    it "does not require a bare Array or Range to be frozen, matching ActiveModel's own native handling" do
      expect { build_axn { expects :v, inclusion: [1, 2] } }.not_to raise_error
      expect { build_axn { expects :v, inclusion: 1..10 } }.not_to raise_error

      unfrozen_range_subclass = Class.new(Range)
      expect { build_axn { expects :v, inclusion: { in: unfrozen_range_subclass.new(1, 10) } } }.not_to raise_error
    end

    # `certainly_resolved_per_call?` alone (a real, public `call` in the table) is NOT routing certainty: an
    # overridden `respond_to?` can hide that `call` behind a `false` answer for `:call` specifically, routing
    # `resolve_value` to the mutable `include?` instead — measured, real ActiveModel enforces via `include?`
    # here and mutating the still-held object after declaring changes membership retroactively. The freeze
    # exemption must require `certainly_routed_to_call?`, not merely a real `call`, before standing down
    # (Codex, PR #288).
    it "refuses an unfrozen delimiter whose real call is hidden by an overridden respond_to?, routing to the mutable include? instead" do
      stub_const("HiddenCallMutableMembership", Class.new do
        def initialize(members) = @members = members
        def include?(value) = @members.include?(value)
        def call = [1, 2, 3]
        def respond_to?(name, *args) = name == :call ? false : super
      end)

      expect { build_axn { expects :v, inclusion: HiddenCallMutableMembership.new([1, 2, 3]) } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class HiddenCallMutableMembership that is not frozen/)

      frozen = HiddenCallMutableMembership.new([1, 2, 3]).freeze
      action = build_axn { expects :v, inclusion: frozen }
      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end

    # A Set/Hash with code of its own (`hash_keyed_set_members` stands down, reading nothing out) is exactly
    # as usable-or-not as any other custom `include?`-answering object — but the hash-keyed branch used to
    # check ONLY `frozen?`, never `usable_clusivity_delimiter?`, so a frozen Set with a broken singleton
    # `include?` declared cleanly and raised on every call (Codex, PR #288: "this early return bypasses
    # usable_clusivity_delimiter? entirely for hash-keyed containers").
    it "refuses a frozen Set SUBCLASS whose singleton include? cannot accept the value ActiveModel always supplies" do
      stub_const("ZeroArgIncludeSet", Class.new(Set))
      broken = ZeroArgIncludeSet[1, 2, 3]
      def broken.include? = true
      broken.freeze

      expect { build_axn { expects :v, inclusion: broken } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class ZeroArgIncludeSet, which ActiveModel cannot use/)
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

  # Two ways ActiveModel's OWN `check_validity!`/`resolve_value` pair can accept and correctly enforce a
  # delimiter through the caller's own dynamic dispatch, which axn's guard used to refuse (Codex, PR #288):
  describe "delimiters resolved through the caller's own dynamic dispatch, which now WORK" do
    # `check_validity!` calls `delimiter.respond_to?(...)` directly — Ruby dispatches whichever the caller's
    # class defines, so overriding `respond_to?` ITSELF (not just the conventional `respond_to_missing?` hook)
    # governs the answer just as completely. The actual membership dispatch (`include?`) then reaches
    # `method_missing` via `public_send`, which never consults `respond_to?` at all.
    it "declares and enforces a delimiter whose respond_to? is overridden directly, with include? reached through method_missing" do
      proxy = Object.new
      def proxy.respond_to?(name, *a) = name == :include? || super
      def proxy.method_missing(name, *args) = name == :include? ? args.first == 1 : super # rubocop:disable Style/MissingRespondToMissing
      proxy.freeze

      action = build_axn { expects :v, inclusion: { in: proxy } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
    end

    # A genuinely public `to_sym` clears `check_validity!` on its own (no doubtful hook needed at all), but
    # `resolve_value` never actually calls `to_sym` — a non-Symbol falls through to `members = value` and then
    # `value.include?(record_value)` via `public_send`. When that `include?` is reached only through
    # `method_missing`, the object is still usable end to end, even with no `respond_to_missing?`/`respond_to?`
    # override at all: `public_send` doesn't consult either.
    it "declares and enforces a to_sym-only delimiter whose include? is reached through method_missing" do
      stub_const("ToSymPlusMethodMissing", Class.new do
        def to_sym = :whatever
        def method_missing(name, *args) = name == :include? ? args.first == 1 : super # rubocop:disable Style/MissingRespondToMissing
      end)

      action = build_axn { expects :v, inclusion: { in: ToSymPlusMethodMissing.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
    end

    # `resolve_value`'s `else` branch checks `respond_to?(:call)` before anything reaches `include?`. A String
    # subclass that answers that DYNAMICALLY — through a cooperating `respond_to_missing?` + `method_missing`
    # pair, not a real `call` method — is resolved through `.call` all the same, never through its inherited
    # substring `include?` (Codex, PR #288).
    it "does not refuse a String SUBCLASS whose call is reached only through a cooperating respond_to_missing?/method_missing pair" do
      stub_const("DynamicCallString", Class.new(String) do
        def respond_to_missing?(name, *) = name == :call || super
        def method_missing(name, *args) = name == :call ? %w[a b] : super
      end)

      action = build_axn { expects :v, inclusion: DynamicCallString.new("irrelevant").freeze }

      expect(outcome(action.call(v: "a"))).to eq(:pass)
      expect(outcome(action.call(v: "z"))).to eq(:reject)
    end

    # Ruby routes a call it cannot dispatch normally — an absent method, or a PRIVATE one reached with an
    # explicit receiver — through `method_missing` regardless of why the normal dispatch failed. So a
    # `respond_to?` narrowed to private, alongside a `method_missing` that cooperates by handling the
    # `:respond_to?` message itself, genuinely answers `check_validity!`'s probe rather than raising
    # `NoMethodError: private method` — the fresh case beyond a private `respond_to?` with no `method_missing`
    # to catch it (Codex, PR #288).
    it "declares and enforces a delimiter whose private respond_to? is caught by a cooperating method_missing" do
      stub_const("PrivateRespondToWithMethodMissing", Class.new do
        # rubocop:disable Style/MissingRespondToMissing -- respond_to? itself is the cooperating hook here
        def method_missing(name, *args)
          return (args.first == :include?) if name == :respond_to?
          return args.first == 1 if name == :include?

          super
        end
        # rubocop:enable Style/MissingRespondToMissing
        private :respond_to?
      end)

      action = build_axn { expects :v, inclusion: { in: PrivateRespondToWithMethodMissing.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
    end

    # `undef_method :respond_to?` leaves NO owner in the method table at all — genuinely different from
    # narrowing it to private, which still leaves an owner `method_owner` can find. Ruby routes the call
    # through `method_missing` all the same, since it cannot dispatch normally either way (Codex, PR #288).
    it "declares and enforces a delimiter whose undefined respond_to? is caught by a cooperating method_missing" do
      stub_const("UndefRespondToWithMethodMissing", Class.new do
        # rubocop:disable Style/MissingRespondToMissing -- respond_to? itself is the cooperating hook here
        def method_missing(name, *args)
          return (args.first == :include?) if name == :respond_to?
          return args.first == 1 if name == :include?

          super
        end
        # rubocop:enable Style/MissingRespondToMissing
        undef_method :respond_to?
      end)

      action = build_axn { expects :v, inclusion: { in: UndefRespondToWithMethodMissing.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
    end

    # `enumerable.is_a? Range` and `members.public_send(...)` are ordinary calls with an explicit receiver,
    # so — same as `respond_to?` above — Ruby routes them through `method_missing` when it cannot dispatch
    # normally, regardless of why (undefined here). A delimiter with BOTH undefined, caught by a cooperating
    # `method_missing`, still declares and enforces correctly (Codex, PR #288).
    it "declares and enforces a delimiter whose is_a? and public_send are both undefined, caught by a cooperating method_missing" do
      stub_const("UndefIsAAndPublicSend", Class.new do
        undef_method :is_a?
        undef_method :public_send

        def method_missing(name, *args)
          return false if name == :is_a?
          return send(*args) if name == :public_send
          return args.first == 1 if name == :include?

          super
        end

        def respond_to_missing?(name, *) = name == :include?
      end)

      action = build_axn { expects :v, inclusion: { in: UndefIsAAndPublicSend.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
    end

    # `resolve_value`'s "else" branch asks `value.respond_to?(:call)` — dispatched to WHICHEVER `respond_to?`
    # the caller's class defines, same as `check_validity!`'s own probe. An override hiding a REAL `call`
    # behind a `false` answer routes to `include?` instead, so the `call`'s own (here, wrong) arity is never
    # reached at all — refusing for it would refuse a declaration that genuinely works (Codex, PR #288).
    it "declares and enforces a delimiter whose real call is hidden by an overridden respond_to?, routing to include? instead" do
      stub_const("HiddenCallDelimiter", Class.new do
        def include?(value) = [1, 2, 3].include?(value)
        def call = [1, 2, 3]
        def respond_to?(name, *args) = name == :call ? false : super
      end)

      action = build_axn { expects :v, inclusion: { in: HiddenCallDelimiter.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end

    # The mirror: a cooperating `respond_to_missing?`/`method_missing` pair can supply a DYNAMIC `call` with
    # no real `call` method at all, routing `resolve_value` there instead of ever reaching `members = value`
    # — so `is_a?`/`cover?`/`include?` apply to whatever `.call` returns, never to the original delimiter. A
    # broken arity on the ORIGINAL object's own `is_a?` is irrelevant, since it is never dispatched (Codex,
    # PR #288).
    it "declares and enforces a delimiter whose own is_a? would be broken, since a dynamic call intercepts routing first" do
      stub_const("DynamicCallOverBrokenIsA", Class.new do
        def is_a? = false

        def respond_to_missing?(name, *) = name == :call || super

        def method_missing(name, *args)
          return [1, 2, 3] if name == :call

          super
        end
      end)

      action = build_axn { expects :v, inclusion: { in: DynamicCallOverBrokenIsA.new.freeze } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end
  end

  # A literal Proc is a SPECIAL case within `resolve_value` — its `case value; when Proc` branch takes
  # absolute precedence over the generic "else" (`respond_to?(:call)`) path every other callable object goes
  # through, and it reads `value.arity` to decide whether to call with zero or one argument
  # (`value.arity == 0 ? value.call : value.call(record)`), rather than always supplying one the way the
  # generic path does.
  describe "a literal Proc — arity-adaptive call, never the generic one-argument requirement" do
    # A zero-arity Proc's `call` is invoked with ZERO arguments, so a SINGLETON `call` override narrowed to
    # match (also zero-arg) is exactly what gets dispatched — requiring one argument here (the generic
    # callable-object rule) would refuse a declaration ActiveModel and the runtime both accept (Codex, PR
    # #288).
    it "declares and enforces a zero-arity Proc whose singleton call is also zero-arg" do
      delimiter = -> { [1, 2, 3] }
      def delimiter.call = [1, 2, 3]

      action = build_axn { expects :v, inclusion: delimiter }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end

    # `resolve_value` calls `value.arity` with ZERO arguments, ALWAYS, before ever deciding how to call
    # `call` itself. A singleton `arity` override requiring an argument is certain `ArgumentError` on that
    # very first read, before `call`'s own (here, perfectly fine) arity ever matters (Codex, PR #288).
    it "refuses a Proc whose singleton arity cannot accept the zero arguments ActiveModel always supplies" do
      delimiter = -> { [1, 2, 3] }
      def delimiter.arity(_required) = 0

      expect { build_axn { expects :v, inclusion: delimiter } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class Proc, which ActiveModel cannot use/)
    end

    # `arity`'s trustworthy VALUE (native `::Proc` ownership confirmed) selects EXACTLY zero or one argument
    # for `call` — not "either", the permissive fallback reserved for when `arity` is overridden and its
    # value genuinely unknowable. A zero-arity Proc's singleton `call` requiring one argument is only ever
    # invoked with zero, so it is never reachable at all (Codex, PR #288).
    it "refuses a zero-arity Proc whose singleton call requires an argument it is never given" do
      delimiter = -> { [1, 2, 3] }
      def delimiter.call(_record) = [1, 2, 3]

      expect { build_axn { expects :v, inclusion: delimiter } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class Proc, which ActiveModel cannot use/)
    end

    # The mirror: a one-arity Proc's singleton `call` accepting zero arguments is only ever invoked with one
    # (the record), so it is equally unreachable (Codex, PR #288).
    it "refuses a one-arity Proc whose singleton call accepts no arguments" do
      delimiter = ->(_record) { [1, 2, 3] }
      def delimiter.call = [1, 2, 3]

      expect { build_axn { expects :v, inclusion: delimiter } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class Proc, which ActiveModel cannot use/)
    end

    # Ruby routes a call it cannot dispatch normally — an absent method, or a PRIVATE one reached with an
    # explicit receiver — through `method_missing` regardless of why normal dispatch failed, the same fact
    # `respond_to_reachable?`/`range_cover_resolution` already depend on. A private singleton `arity` backed
    # by a cooperating `method_missing` genuinely answers `value.arity` (Codex, PR #288: "Ruby routes an
    # explicit call to the private method through method_missing, just as the surrounding delimiter checks
    # already allow for other inaccessible methods").
    it "declares and enforces a Proc whose singleton arity is private, caught by a cooperating method_missing" do
      delimiter = -> { [1, 2, 3] }
      # rubocop:disable Style/MissingRespondToMissing -- respond_to_missing? only needs to cover :arity
      def delimiter.method_missing(name, *args)
        return 0 if name == :arity

        super
      end
      # rubocop:enable Style/MissingRespondToMissing
      class << delimiter
        def arity = 0
        private :arity
      end

      action = build_axn { expects :v, inclusion: delimiter }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 5))).to eq(:reject)
    end

    # `Proc#call`'s own method-table signature is ALWAYS `(*args)`, generically, across every Proc instance —
    # only the SPECIFIC closure's own `parameters` reveal a 2-required-arg lambda's real strictness.
    # `resolve_value`'s Proc branch calls with AT MOST one argument (zero or one, decided by `arity`), so a
    # lambda requiring two can never be satisfied and must be refused outright, not accepted on the strength
    # of `Proc#call`'s generic signature (Codex, PR #288: "arities greater than one and required keywords
    # must be rejected from the Proc's own parameters").
    it "refuses a Proc whose own body requires two arguments, which resolve_value never supplies" do
      delimiter = ->(_record, _second) { [1, 2, 3] }

      expect { build_axn { expects :v, inclusion: delimiter } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class Proc, which ActiveModel cannot use/)
    end
  end

  # `own_method_missing_hook?` establishes that a doubtful hook is BACKED by `method_missing`, but not that
  # `method_missing` itself can accept what Ruby will actually invoke it with —
  # `method_missing(missed_name, *original_args)` — a question distinct from mere existence, and checked
  # throughout this file via `method_missing_accepts?` (Codex, PR #288, a second round after the
  # `respond_to?`-fallback fix: every other doubtful-hook fallback had the same gap).
  describe "a doubtful hook backed by a method_missing that cannot accept what it would actually be invoked with" do
    # `resolve_value`'s dynamic `.call(record)` route, reached through a cooperating `respond_to_missing?`
    # with no real `call` method, dispatches `method_missing(:call, record)` — TWO args. A one-argument
    # `method_missing(name)` cannot accept that, so the declaration must be refused rather than accepted on
    # ownership alone (Codex, PR #288).
    it "refuses a delimiter whose dynamic call route is backed by a method_missing accepting only the message name" do
      stub_const("DynamicCallOneArgMethodMissing", Class.new do
        def respond_to_missing?(name, *) = name == :call || super

        def method_missing(name) = name == :call ? [1, 2, 3] : super
      end)

      expect { build_axn { expects :v, inclusion: DynamicCallOneArgMethodMissing.new.freeze } }
        .to raise_error(ArgumentError, /inclusion: on :v names a set of class DynamicCallOneArgMethodMissing, which ActiveModel cannot use/)
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

  # The guard mirrors `check_validity!` by OWNERSHIP (a method-table lookup), never by dispatching
  # `respond_to?`/`is_a?`/`inspect` on the caller's own delimiter — the same rule
  # `certainly_resolved_per_call?` already follows in this file. Doubt must answer "usable": refusing an
  # undecidable delimiter would refuse a declaration ActiveModel might in fact accept.
  describe "ownership, not dispatch" do
    it "declares a delimiter reachable only through the caller's own method_missing (doubt permits)" do
      liar = Object.new
      def liar.method_missing(name, *) = name == :include? ? true : super
      def liar.respond_to_missing?(name, _include_private = false) = name == :include? || super
      liar.freeze

      expect { build_axn { expects :v, inclusion: { in: liar } } }.not_to raise_error
    end

    # `check_validity!` is built entirely out of `respond_to?` checks, and `respond_to?` consults only
    # `respond_to_missing?` for a name absent from the method table — never `method_missing`. So a
    # `method_missing` override with no matching `respond_to_missing?` is NOT doubtful the way the cooperating
    # pair above is: `respond_to?` deterministically answers false regardless of what `method_missing`
    # implements, and `check_validity!` raises ActiveModel's own `ArgumentError` on every call (Codex, PR #288).
    it "refuses a delimiter reachable only through method_missing, with no respond_to_missing? to back it" do
      liar = Object.new
      def liar.method_missing(name, *) = name == :include? ? true : super # rubocop:disable Style/MissingRespondToMissing

      expect { build_axn { expects :v, inclusion: { in: liar } } }
        .to raise_error(ArgumentError, /names a set of class Object, which ActiveModel cannot use/)
    end

    it "never calls the caller's own is_a?/inspect while judging or reporting an unusable delimiter" do
      dispatched = []
      hostile = Object.new
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

    # A caller who overrides `respond_to?` ITSELF (rather than the conventional `respond_to_missing?` hook)
    # governs `check_validity!`'s answer just as completely, and just as undecidably without running it —
    # DOUBT MUST ANSWER "usable" here too (Codex, PR #288). Still never DISPATCHED by axn's own declaration-time
    # judgment: `dispatched` only ever grows once the action actually calls, from ActiveModel's real runtime
    # probe, never from `build_axn` itself.
    it "declares a delimiter reachable only through the caller's own overridden respond_to? (doubt permits), never dispatching it at declaration" do
      dispatched = []
      tracking = false
      proxy = Object.new
      proxy.define_singleton_method(:respond_to?) do |name, *a|
        dispatched << :respond_to? if tracking
        name == :include? || super(name, *a)
      end
      proxy.define_singleton_method(:method_missing) { |name, *args| name == :include? ? args.first == 1 : super(name, *args) }
      proxy.freeze

      action = nil
      expect { action = build_axn { expects :v, inclusion: { in: proxy } } }.not_to raise_error
      expect(dispatched).to eq([])

      tracking = true
      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
      expect(dispatched).not_to be_empty
    end

    # `respond_to?`/`respond_to_missing?` participate in NEITHER `public_send`'s dispatch nor an ordinary
    # `.call` — only `method_missing` can catch a message absent from the method table. An object whose
    # `respond_to_missing?` (or `respond_to?`) CLAIMS `:include?` with no `method_missing` to back it still
    # raises `NoMethodError` from the real dispatch, for certain — the doubt a lone `respond_to?` hook grants
    # is worthless without a dispatch hook alongside it (Codex, PR #288).
    it "refuses a delimiter whose respond_to_missing? claims include? with no method_missing to back it" do
      liar = Object.new
      def liar.respond_to_missing?(name, *) = name == :include? || super

      expect { build_axn { expects :v, inclusion: { in: liar } } }
        .to raise_error(ArgumentError, /names a set of class Object, which ActiveModel cannot use/)
    end

    it "refuses a delimiter whose overridden respond_to? claims include? with no method_missing to back it" do
      liar = Object.new
      def liar.respond_to?(name, *a) = name == :include? || super

      expect { build_axn { expects :v, inclusion: { in: liar } } }
        .to raise_error(ArgumentError, /names a set of class Object, which ActiveModel cannot use/)
    end
  end
end
