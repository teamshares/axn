# frozen_string_literal: true

require "date"

# Ruby's own resolution of the question `method_owner` answers, which it must agree with for every method that
# EXISTS. Bound rather than dispatched, for the same reason the module under test binds everything.
NATIVE_METHODS_SPEC_OBJECT_METHOD = Object.instance_method(:method)

# Records that Ruby consulted the OBJECT about a name instead of reading it out of a method table. Ruby passes
# `include_private = true` from an owner lookup and `false` from a plain `respond_to?`, so the hook records both
# and an example can tell which kind of lookup reached it.
module RespondToMissingProbe
  def self.reset! = @calls = []
  def self.calls = @calls ||= []

  def respond_to_missing?(name, include_private = false)
    RespondToMissingProbe.calls << [name, include_private]
    false
  end
end

# The module's promise is that it answers ownership questions WITHOUT running a line the caller's object wrote.
# That promise cannot be pinned by asserting an outcome: a predicate that dispatched the object's code and then
# rescued whatever came back answers correctly too, and differs only when the code has an effect no rescue can
# undo. So the assertions here come in pairs — one on the answer, one on a FLAG the object's own hook sets — and
# it is the flag that pins "no foreign code".
RSpec.describe Axn::Internal::NativeMethods do
  before { RespondToMissingProbe.reset! }

  describe ".method_owner" do
    # Every shape a caller's object can present a method in, and the owner read out of the method table has to be
    # the one Ruby would dispatch in each. The singleton and extended-module rows are why the lookup asks the
    # object's SINGLETON CLASS rather than its class: only that module's ancestry contains them. The rows that
    # refuse a singleton class are why there is a fallback to the class at all.
    #
    # Parity is asserted against `Object#method` rather than against a hard-coded owner, so an example cannot
    # pass by agreeing with a stale expectation — the two resolutions are compared on the same object.
    {
      "a plain instance" => [-> { String.new("x") }, :to_s],
      "a subclass that INHERITS the method" => [-> { Class.new(String).new("x") }, :to_s],
      "a subclass that OVERRIDES it" => [-> { Class.new(String) { def to_s = "own" }.new("x") }, :to_s],
      "a singleton method" => [-> { String.new("x").tap { |s| s.define_singleton_method(:to_s) { "own" } } }, :to_s],
      "a module EXTENDED onto the object" => [-> { String.new("x").tap { |s| s.extend(Module.new { def to_s = "own" }) } }, :to_s],
      "a module PREPENDED to the class" => [-> { Class.new(String) { prepend(Module.new { def to_s = "own" }) }.new("x") }, :to_s],
      "a private method" => [-> { Class.new { private def secret = 1 }.new }, :secret],
      "a protected method" => [-> { Class.new { protected def guarded = 1 }.new }, :guarded],
      "an inherited Kernel method" => [-> { Object.new }, :puts],
      "an Integer, which refuses a singleton class" => [-> { 7 }, :to_s],
      "a Symbol, which refuses a singleton class" => [-> { :sym }, :to_s],
      "a Float, which refuses a singleton class" => [-> { 1.5 }, :to_s],
      "an interned frozen String literal, which refuses one too" => [-> { "interned" }, :to_s],
      "a frozen object, which does NOT refuse one" => [-> { String.new("x").freeze }, :to_s],
      "a frozen exception" => [-> { StandardError.new("x").freeze }, :exception],
      "nil" => [-> {}, :to_s],
      "a BasicObject" => [-> { Class.new(BasicObject) { def zap = 1 }.new }, :zap],
    }.each do |label, (build, name)|
      it "resolves #{label} to the owner Ruby's own dispatch would" do
        value = build.call

        expect(described_class.method_owner(value, name)).to equal(NATIVE_METHODS_SPEC_OBJECT_METHOD.bind_call(value, name).owner)
      end
    end

    it "answers nil for a method nothing defines" do
      expect(described_class.method_owner(Object.new, :nope_not_here)).to be_nil
    end

    # `undef_method` leaves a marker that makes the name UNDISPATCHABLE, so the implementation it shadows is not
    # what answers and must not be reported as the owner. Reporting `String` here would be wrong in the unsafe
    # direction: a caller reading that owner concludes the built-in answers, and calls it.
    it "answers nil for an undef'd method rather than the implementation it shadows" do
      klass = Class.new(String) { undef_method :to_s }

      expect(described_class.method_owner(klass.new("x"), :to_s)).to be_nil
    end

    # A `method_missing`-backed method is reported ABSENT. It is by definition the object's own code, so no
    # built-in owner can ever be the right answer, and every caller compares the owner against a specific
    # built-in — so "absent" and "the object's own class" take the identical branch everywhere.
    it "answers nil for a method served only by method_missing" do
      value = Class.new do
        def respond_to_missing?(name, _include_private = false) = name == :zap
        def method_missing(name, *args) = name == :zap ? "zapped" : super
      end.new

      expect(described_class.method_owner(value, :zap)).to be_nil
    end

    context "the promise: the lookup runs none of the object's code" do
      # ABSENCE is the case that matters, and it is not hypothetical — `facade_inspector` asks for a `to_fs` that
      # exists in no process without ActiveSupport's conversions loaded. A lookup put to the VALUE consults its
      # `respond_to_missing?` on exactly that path.
      it "does not consult respond_to_missing? for an ABSENT method" do
        value = Class.new { include RespondToMissingProbe }.new

        expect(described_class.method_owner(value, :nope_not_here)).to be_nil
        expect(RespondToMissingProbe.calls).to be_empty
      end

      it "does not consult respond_to_missing? for a PRESENT method" do
        value = Class.new(String) { include RespondToMissingProbe }.new("x")

        expect(described_class.method_owner(value, :to_s)).to equal(String)
        expect(RespondToMissingProbe.calls).to be_empty
      end

      # The same object, asked the same question through Ruby's own lookup — which is what makes the two
      # assertions above mean anything. Without it, an empty call list would also be satisfied by a hook that is
      # not wired up and can never fire at all.
      it "is reached by Ruby's own Object#method, so an empty call list is evidence" do
        value = Class.new { include RespondToMissingProbe }.new

        expect { NATIVE_METHODS_SPEC_OBJECT_METHOD.bind_call(value, :nope_not_here) }.to raise_error(NameError)
        expect(RespondToMissingProbe.calls).to eq([[:nope_not_here, true]])
      end

      # A hook that RAISES is what turns the dispatch from a wasted call into a replaced verdict, and
      # `NotImplementedError` is outside StandardError, so no rescue in this predicate's callers contains it.
      it "answers rather than propagating an exception raised by respond_to_missing?" do
        value = Class.new do
          def respond_to_missing?(*) = raise(NotImplementedError, "hook fired")
        end.new

        expect(described_class.method_owner(value, :nope_not_here)).to be_nil
      end
    end
  end

  # The value-level twin of `declared_instance_method`, and the ONE lookup `method_owner` reads — so the matrix
  # above is this method's matrix too, and the last example here is what keeps the two from drifting. What it adds
  # is the method ITSELF, for a caller that has to CALL what the table declares rather than only name its owner.
  describe ".declared_method" do
    # An UnboundMethod resolved from the value's own method table binds back to that value and dispatches exactly
    # what Ruby would have. The singleton, extended and prepended rows are the ones a lookup against the CLASS
    # would get wrong, which is why the resolution goes through the singleton class.
    {
      "a plain instance" => [-> { Class.new { def zap = :from_class }.new }, :from_class],
      "a subclass that OVERRIDES the method" => [-> { Class.new(Class.new { def zap = :inherited }) { def zap = :own }.new }, :own],
      "a singleton method" => [-> { Object.new.tap { |o| o.define_singleton_method(:zap) { :from_singleton } } }, :from_singleton],
      "a module EXTENDED onto the object" => [-> { Object.new.tap { |o| o.extend(Module.new { def zap = :from_extend }) } }, :from_extend],
      "a module PREPENDED to the class" => [
        -> { Class.new { def zap = :from_class }.tap { |k| k.prepend(Module.new { def zap = :from_prepend }) }.new }, :from_prepend
      ],
      "a private method" => [-> { Class.new { private def zap = :from_private }.new }, :from_private],
      "a BasicObject" => [-> { Class.new(BasicObject) { def zap = :from_basic }.new }, :from_basic],
    }.each do |label, (build, expected)|
      it "resolves #{label} to a method that binds back to the value" do
        value = build.call

        expect(described_class.declared_method(value, :zap).bind_call(value)).to eq(expected)
      end
    end

    # The singleton-class refusal the class fallback exists for: the method still has to be callable.
    it "resolves a name an immediate answers, which refuses a singleton class" do
      expect(described_class.declared_method(7, :to_s).bind_call(7)).to eq("7")
    end

    it "answers nil for a name nothing defines" do
      expect(described_class.declared_method(Object.new, :nope_not_here)).to be_nil
    end

    it "answers nil for an undef'd name rather than the implementation it shadows" do
      expect(described_class.declared_method(Class.new(String) { undef_method :to_s }.new("x"), :to_s)).to be_nil
    end

    # ABSENT by design, on the same terms as `method_owner`: `method_missing` is the object's own code, never a
    # definition the table holds. A caller that must still READ such a member falls back to a dispatch of its own
    # — which is what `ShapeGraph.fetch` does, and why reporting absent here costs it nothing.
    it "answers nil for a name served only by method_missing" do
      value = Class.new do
        def respond_to_missing?(name, _include_private = false) = name == :zap
        def method_missing(name, *args) = name == :zap ? "zapped" : super
      end.new

      expect(described_class.declared_method(value, :zap)).to be_nil
    end

    context "the promise: the lookup runs none of the object's code" do
      it "does not consult respond_to_missing? for an ABSENT name" do
        value = Class.new { include RespondToMissingProbe }.new

        expect(described_class.declared_method(value, :nope_not_here)).to be_nil
        expect(RespondToMissingProbe.calls).to be_empty
      end

      it "does not consult respond_to_missing? for a PRESENT name" do
        value = Class.new(String) { include RespondToMissingProbe }.new("x")

        expect(described_class.declared_method(value, :to_s).bind_call(value)).to eq("x")
        expect(RespondToMissingProbe.calls).to be_empty
      end

      # A hook that RAISES is what turns the dispatch from a wasted call into a replaced verdict, and
      # `NotImplementedError` is outside StandardError, so no rescue in this lookup's callers contains it.
      it "answers rather than propagating an exception raised by respond_to_missing?" do
        value = Class.new { def respond_to_missing?(*) = raise(NotImplementedError, "hook fired") }.new

        expect(described_class.declared_method(value, :nope_not_here)).to be_nil
      end
    end

    # The consolidation itself. `method_owner` is this lookup's owner, so the two cannot drift into separate reads
    # with separate absence policies — which is the defect that produced three of them once already.
    it "is the lookup `method_owner` reports the owner of" do
      [String.new("x"), 7, nil, Object.new, Class.new(String) { undef_method :to_s }.new("x")].each do |value|
        expect(described_class.method_owner(value, :to_s)).to equal(described_class.declared_method(value, :to_s)&.owner)
      end
    end
  end

  # Each predicate below reads that one owner lookup. The pairs assert that the ANSWER is what it has to be for
  # an ordinary object, and that reaching it consulted the object about nothing.
  describe "the predicates that read an owner" do
    describe ".native_exception_reraise?" do
      it "is true for an ordinary exception" do
        expect(described_class.native_exception_reraise?(StandardError.new("x"))).to be(true)
      end

      it "is true for a frozen exception, which `raise` hands back unchanged" do
        expect(described_class.native_exception_reraise?(StandardError.new("x").freeze)).to be(true)
      end

      it "is false for one that owns #exception" do
        hijacker = Class.new(StandardError) { def exception(*) = ArgumentError.new("substituted") }.new

        expect(described_class.native_exception_reraise?(hijacker)).to be(false)
      end

      # The shape the guard degrades for: `#exception` removes itself while answering the raise, so the owner
      # lookup that follows is asked about a method that no longer exists.
      it "is false, consulting respond_to_missing? about nothing, when #exception has undefined itself" do
        error = Class.new(StandardError) do
          include RespondToMissingProbe

          def exception(*)
            self.class.send(:undef_method, :exception)
            self
          end
        end.new("original")

        begin
          raise error
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end
        RespondToMissingProbe.reset!

        expect(described_class.native_exception_reraise?(error)).to be(false)
        expect(RespondToMissingProbe.calls).to be_empty
      end
    end

    describe ".native_exception_reporting?" do
      it "is true for an ordinary exception" do
        expect(described_class.native_exception_reporting?(StandardError.new("x"))).to be(true)
      end

      it "is false for a frozen one, whose clone cannot take the new message" do
        expect(described_class.native_exception_reporting?(StandardError.new("x").freeze)).to be(false)
      end

      it "is false for one owning a duplication hook" do
        error = Class.new(StandardError) do
          def initialize_copy(other)
            super
            @copied = true
          end
        end.new

        expect(described_class.native_exception_reporting?(error)).to be(false)
      end

      it "consults respond_to_missing? about nothing" do
        error = Class.new(StandardError) { include RespondToMissingProbe }.new("x")

        expect(described_class.native_exception_reporting?(error)).to be(true)
        expect(RespondToMissingProbe.calls).to be_empty
      end
    end

    describe ".native_name_rendering?" do
      it "is true for a Symbol" do
        expect(described_class.native_name_rendering?(:field)).to be(true)
      end

      it "is true for a plain String" do
        expect(described_class.native_name_rendering?("field")).to be(true)
      end

      it "is true for a frozen String literal, which refuses a singleton class" do
        expect(described_class.native_name_rendering?("field")).to be(true)
      end

      it "is true for a String subclass that INHERITS #to_s" do
        expect(described_class.native_name_rendering?(Class.new(String).new("field"))).to be(true)
      end

      it "is false for a String subclass that defines #to_s" do
        name = Class.new(String) { def to_s = "other" }.new("field")

        expect(described_class.native_name_rendering?(name)).to be(false)
      end

      it "is false for a String carrying a singleton #to_s" do
        name = String.new("field")
        name.define_singleton_method(:to_s) { "other" }

        expect(described_class.native_name_rendering?(name)).to be(false)
      end

      it "is false for a String whose #to_s has been undef'd" do
        name = Class.new(String) { undef_method :to_s }.new("field")

        expect(described_class.native_name_rendering?(name)).to be(false)
      end

      it "is false for anything that is neither a String nor a Symbol" do
        expect(described_class.native_name_rendering?(Object.new)).to be(false)
      end

      it "consults respond_to_missing? about nothing" do
        name = Class.new(String) { include RespondToMissingProbe }.new("field")

        expect(described_class.native_name_rendering?(name)).to be(true)
        expect(RespondToMissingProbe.calls).to be_empty
      end
    end
  end

  # The two remaining readers of an owner, whose ordinary answers this pins alongside the promise.
  describe "the availability checks built on the owner lookup" do
    # `to_fs` is ActiveSupport's, and axn deliberately does not load the core_exts that define it — so ABSENCE is
    # this caller's ORDINARY case, not an exotic one, which makes it the strongest place to pin that an absent
    # lookup asks the value nothing. How the fallback then renders is covered in
    # `spec/axn/core/mixed_encoding_compositions_spec.rb`.
    #
    # `to_fs` is UNDEFINED on the probe rather than assumed missing from the process, on the same reasoning that
    # file states: whether ActiveSupport's conversions are loaded is not this file's to decide, since another spec
    # in this suite pulls them in transitively, so an example that assumed otherwise would pass or fail on file
    # ordering. Both states give the same answer here — an undef'd name and an absent one are equally
    # undispatchable, and neither is read by asking the value.
    describe "facade inspection of a timestamp" do
      let(:probe_date) do
        Class.new(Date) do
          include RespondToMissingProbe
          undef_method(:to_fs) if method_defined?(:to_fs)
        end.new(2026, 8, 4)
      end

      it "finds no to_fs owner, and asks the value about nothing on the way" do
        expect(described_class.method_owner(probe_date, :to_fs)).to be_nil
        expect(RespondToMissingProbe.calls).to be_empty
      end

      # A name that is absent whatever is loaded, so the pure-absence branch is covered deterministically
      # alongside the undef one above.
      it "asks the value nothing about a name no gem could have defined" do
        expect(described_class.method_owner(probe_date, :to_fs_nope_not_here)).to be_nil
        expect(RespondToMissingProbe.calls).to be_empty
      end
    end

    # `Reflection::Schema` decides whether a declared default is an empty container by WHOSE `empty?` would
    # answer it, then calls the implementation whose owner it just established.
    describe "the emptiness of a declared default" do
      it "recognizes the built-in containers" do
        expect(described_class.method_owner({}, :empty?)).to equal(Hash)
        expect(described_class.method_owner([], :empty?)).to equal(Array)
        expect(described_class.method_owner("", :empty?)).to equal(String)
      end

      it "recognizes a subclass that inherits the built-in's implementation" do
        expect(described_class.method_owner(Class.new(Hash).new, :empty?)).to equal(Hash)
      end

      it "does not credit a subclass that overrides it" do
        overriding = Class.new(Hash) { def empty? = true }.new

        expect(described_class.method_owner(overriding, :empty?)).not_to equal(Hash)
      end

      it "finds no owner on an object with no empty?, without asking the object" do
        value = Class.new { include RespondToMissingProbe }.new

        expect(described_class.method_owner(value, :empty?)).to be_nil
        expect(RespondToMissingProbe.calls).to be_empty
      end
    end
  end

  describe ".own_public_instance_methods" do
    it "lists only the module's own public methods" do
      parent = Module.new { def inherited_one = nil }
      mod = Module.new do
        include parent
        def public_one = nil
        def private_one = nil
        private :private_one
      end

      expect(described_class.own_public_instance_methods(mod)).to eq([:public_one])
    end

    it "reads the table natively rather than dispatching" do
      mod = Module.new do
        def self.instance_methods(*) = raise("hijacked")
        def self.public_instance_methods(*) = raise("hijacked")
        def public_one = nil
      end

      expect(described_class.own_public_instance_methods(mod)).to eq([:public_one])
    end
  end

  describe ".declared_visibility" do
    let(:mod) do
      Module.new do
        def public_one = nil
        def protected_one = nil
        def private_one = nil
        protected :protected_one
        private :private_one
      end
    end

    it "separates the three visibilities a module declares" do
      expect(described_class.declared_visibility(mod, :public_one)).to eq(:public)
      expect(described_class.declared_visibility(mod, :private_one)).to eq(:private)
    end

    # `instance_methods` counts protected methods among the public ones, so a reader written as
    # "public unless private" reports this one public and a caller reproducing the declaration leaks it.
    it "does not report a protected method as public" do
      expect(described_class.declared_visibility(mod, :protected_one)).to eq(:protected)
    end

    it "answers nil for a name the module does not declare, including one it inherits" do
      declaring = mod
      child = Module.new { include declaring }

      expect(described_class.declared_visibility(child, :public_one)).to be_nil
      expect(described_class.declared_visibility(child, :nope_not_here)).to be_nil
    end

    it "reads the table natively rather than dispatching" do
      hijacked = Module.new do
        def self.public_instance_methods(*) = raise("hijacked")
        def self.protected_instance_methods(*) = raise("hijacked")
        def self.private_instance_methods(*) = raise("hijacked")
        def protected_one = nil
        protected :protected_one
      end

      expect(described_class.declared_visibility(hijacked, :protected_one)).to eq(:protected)
    end
  end
end

RSpec.describe Axn::Internal::NativeMethods, ".declared_instance_method" do
  it "answers the UnboundMethod a module defines" do
    mod = Module.new { def greet = "hi" }

    resolved = described_class.declared_instance_method(mod, :greet)

    expect(resolved).to be_a(UnboundMethod)
    expect(resolved.owner).to equal(mod)
  end

  it "answers nil rather than raising when nothing defines the name" do
    expect(described_class.declared_instance_method(Module.new, :nope_not_here)).to be_nil
  end

  # The nil policy is what lets a caller write `…&.owner` / `…&.source_location` and compare, instead of
  # wrapping the lookup in a rescue and inventing a second absence policy — the split `method_owner` exists to
  # prevent.
  it "reports an INHERITED method with the ancestor that owns it" do
    parent = Class.new { def greet = "hi" }
    child = Class.new(parent)

    expect(described_class.declared_instance_method(child, :greet).owner).to equal(parent)
  end

  # ANY visibility on purpose. A caller here asks whether the module DECLARES something of its own, which is
  # what decides whether an inherited implementation still governs — and a non-public definition shadows the
  # inherited one just as completely. `method_defined?` sees protected but not private, and
  # `public_method_defined?` sees neither, so both would call a shadowed built-in "still in force".
  it "reports a definition at every visibility, where the two predicates disagree" do
    klass = Class.new do
      def pub = 1
      def prot = 2
      def priv = 3
      protected :prot
      private :priv
    end

    %i[pub prot priv].each do |name|
      expect(described_class.declared_instance_method(klass, name)&.owner).to equal(klass), "expected to find #{name}"
    end

    # The disagreement this reader exists to sit above.
    expect(klass.method_defined?(:prot)).to be(true)
    expect(klass.method_defined?(:priv)).to be(false)
    expect(klass.public_method_defined?(:prot)).to be(false)
  end

  it "reads from the method table rather than asking the module" do
    liar = Module.new do
      def self.public_method_defined?(*) = raise(NotImplementedError, "must not be asked")
      def self.instance_method(*) = raise(NotImplementedError, "must not be asked")
      def greet = "hi"
    end

    expect(described_class.declared_instance_method(liar, :greet)).to be_a(UnboundMethod)
    expect(described_class.declared_instance_method(liar, :nope)).to be_nil
  end

  # `public_instance_method?` answers the DIFFERENT question — "could a consumer dispatch this?" — and stays
  # the right reader where that is what is being asked (a shape segment that has to be readable).
  it "is deliberately wider than the public-dispatch predicate" do
    klass = Class.new do
      def hidden = 1
      private :hidden
    end

    expect(described_class.declared_instance_method(klass, :hidden)).to be_a(UnboundMethod)
    expect(described_class.public_instance_method?(klass, :hidden)).to be(false)
  end
end

RSpec.describe Axn::Internal::NativeMethods, ".includes_module?" do
  it "answers the ancestry question, receiver included" do
    expect(described_class.includes_module?(Integer, Numeric)).to be(true)
    expect(described_class.includes_module?(Integer, Integer)).to be(true)
    expect(described_class.includes_module?(Integer, String)).to be(false)
  end

  # `Array#include?` compares with `element == other`, and the FIRST element of any class's ancestry is the
  # class itself — so a class carrying its own `==` answered this question about itself, which is the one thing
  # reading the ancestry natively exists to take away from it. Reachable from a declaration guard: a declared
  # `type:` token is the receiver at three call sites.
  it "decides membership by identity, without dispatching the receiver's ==" do
    dispatched = []
    liar = Class.new(Numeric) do
      define_singleton_method(:==) do |other|
        dispatched << other
        true
      end
    end

    expect(described_class.includes_module?(liar, Numeric)).to be(true)
    expect(described_class.includes_module?(liar, String)).to be(false)
    expect(dispatched).to eq([])
  end

  it "is not fooled by a module that answers `ancestors` for itself" do
    liar = Class.new do
      def self.ancestors = [Numeric]
    end

    expect(described_class.includes_module?(liar, Numeric)).to be(false)
  end
end
