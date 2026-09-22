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

      action = build_axn { expects :v, inclusion: { in: ToSymPlusMethodMissing.new } }

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

      action = build_axn { expects :v, inclusion: DynamicCallString.new("irrelevant") }

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

      action = build_axn { expects :v, inclusion: { in: PrivateRespondToWithMethodMissing.new } }

      expect(outcome(action.call(v: 1))).to eq(:pass)
      expect(outcome(action.call(v: 2))).to eq(:reject)
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
      proxy = Object.new
      proxy.define_singleton_method(:respond_to?) do |name, *a|
        dispatched << :respond_to? if @tracking
        name == :include? || super(name, *a)
      end
      proxy.define_singleton_method(:method_missing) { |name, *args| name == :include? ? args.first == 1 : super(name, *args) }

      action = nil
      expect { action = build_axn { expects :v, inclusion: { in: proxy } } }.not_to raise_error
      expect(dispatched).to eq([])

      proxy.instance_variable_set(:@tracking, true)
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
