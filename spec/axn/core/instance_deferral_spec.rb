# frozen_string_literal: true

RSpec.describe Axn::Core::InstanceDeferral do
  let(:parent) do
    Class.new do
      def log(msg, **) = "PARENT-LOG(#{msg})"
      def info(msg, **) = "PARENT-INFO(#{msg})"
    end
  end

  it "lets the inherited definition win over axn's helper" do
    action = Class.new(parent) { include Axn }

    expect(action.send(:new).log("x")).to eq("PARENT-LOG(x)")
  end

  it "leaves the un-shadowed helpers alone" do
    action = Class.new(parent) { include Axn }
    expect(Axn::Internal::NativeMethods.declared_instance_method(action, :fail!).owner).to eq(Axn::Core)
  end

  it "adds no ancestor when the hierarchy owns nothing axn defines" do
    plain = Class.new { include Axn }
    expect(described_class.shim(plain)).to be_nil
    expect(described_class.definers(plain)).to be_empty
  end

  it "records the definer for each deferred name" do
    action = Class.new(parent) { include Axn }
    expect(described_class.definers(action)).to eq(log: parent, info: parent)
  end

  it "forwards positional, keyword and block arguments to the inherited implementation" do
    base = Class.new do
      def log(one, two = nil, *rest, key: nil, **opts, &blk) = [one, two, rest, key, opts, blk&.call]
    end
    action = Class.new(base) { include Axn }

    expect(action.send(:new).log(1, 2, 3, key: 4, other: 5) { 6 }).to eq([1, 2, [3], 4, { other: 5 }, 6])
  end

  it "keeps a Hash passed positionally positional" do
    base = Class.new { def log(payload) = payload }
    action = Class.new(base) { include Axn }

    expect(action.send(:new).log({ level: :warn })).to eq(level: :warn)
  end

  it "lets a class-body def wrap the inherited implementation through super" do
    action = Class.new(parent) do
      include Axn
      def log(msg, **opts) = "WRAPPED[#{super}]"
    end

    expect(action.send(:new).log("x")).to eq("WRAPPED[PARENT-LOG(x)]")
  end

  it "leaves a class-body def written before the include reaching axn's implementation" do
    logged = []
    allow(Axn.config.logger).to receive(:info) { |msg| logged << msg }

    action = Class.new do
      def log(msg, **opts) = super("[wrapped] #{msg}", **opts)
      include Axn
    end
    action.send(:new).log("x")

    expect(logged.first).to include("[wrapped] x")
  end

  it "does not defer for a subclass of an existing action, which re-includes nothing" do
    parent_action = Class.new { include Axn }
    child = Class.new(parent_action) { include Axn }

    expect(described_class.definers(child)).to be_empty
  end

  # `shim` and `definers` answer for the class's OWN record, and a subclass has none: `install` runs on the class
  # that includes Axn. A caller that CHANGES a record depends on exactly that, since editing an ancestor's shim
  # would strip the helper from every class beneath it. `definer_behind` is the read that walks instead.
  it "records nothing on a subclass of a class that did defer" do
    parent_action = Class.new(parent) { include Axn }
    child = Class.new(parent_action)

    expect(described_class.definers(child)).to be_empty
    expect(described_class.shim(child)).to be_nil
    expect(described_class.definer_behind(described_class.shim(parent_action), :log)).to eq(parent)
    expect(Axn::Internal::NameOwnership.owner_of(child, :log)).to eq(parent)
  end

  it "runs the action end to end with a deferred logging helper" do
    action = Class.new(parent) do
      include Axn
      exposes :out
      def call = expose(out: log("hi"))
    end

    result = action.call
    expect(result).to be_ok
    expect(result.out).to eq("PARENT-LOG(hi)")
  end

  it "defers to a definer the class picked up from an included module" do
    concern = Module.new { def log(msg, **) = "CONCERN-LOG(#{msg})" }
    action = Class.new do
      include concern
      include Axn
    end

    expect(described_class.definers(action)).to eq(log: concern)
    expect(action.send(:new).log("x")).to eq("CONCERN-LOG(x)")
  end

  # The deferral reproduces the definer's declaration, which means reproducing its VISIBILITY: a wrapper is
  # defined public unless told otherwise, so without this the action would publish a helper its author kept off
  # the class's surface, and duck-type probes on the instance would start answering differently.
  it "keeps a private definer's method private, still reachable with an implicit receiver" do
    base = Class.new { private def log(msg) = "PRIVATE-LOG(#{msg})" }
    action = Class.new(base) do
      include Axn
      def wrapped = log("x")
    end

    expect(action).not_to be_public_method_defined(:log)
    expect(action.send(:new)).not_to respond_to(:log)
    expect(action.send(:new).wrapped).to eq("PRIVATE-LOG(x)")
  end

  # Protected is its own case rather than a shade of private: collapsing it either way breaks something.
  it "keeps a protected definer's method protected, so one instance can still reach another's" do
    base = Class.new { protected def log(msg) = "PROTECTED-LOG(#{msg})" }
    action = Class.new(base) do
      include Axn
      def log_peer(other) = other.log("x")
    end

    expect(action).not_to be_public_method_defined(:log)
    expect(action).to be_protected_method_defined(:log)
    expect(action.send(:new).log_peer(action.send(:new))).to eq("PROTECTED-LOG(x)")
  end

  it "keeps a public definer's method public" do
    action = Class.new(parent) { include Axn }

    expect(action).to be_public_method_defined(:log)
    # An external dispatch is what public MEANS here; a private or protected wrapper would raise NoMethodError.
    expect(action.send(:new).log("x")).to eq("PARENT-LOG(x)")
  end

  describe "a declaration that collides with a deferred name" do
    let(:named_parent) do
      stub_const("ApplicationService", Class.new { def log(*) = "PARENT" })
      ApplicationService
    end

    it "raises naming the class that owns it, not an anonymous module" do
      action = Class.new(named_parent) { include Axn }

      expect { action.class_eval { expects :log } }.to raise_error(
        Axn::ContractViolation::ReservedAttributeError, /ApplicationService/
      )
    end

    # The wrapper the shim holds is defined in axn's own source, so an owner left unresolved reports a path
    # inside axn for a collision between the author's base class and the field they declared.
    it "does not name axn's own source file" do
      action = Class.new(named_parent) { include Axn }

      expect { action.class_eval { expects :log } }.to raise_error(Axn::ContractViolation::ReservedAttributeError) do |error|
        expect(error.message).not_to include("instance_deferral")
      end
    end

    # One base class includes Axn and the per-action subclasses declare the fields, which is the common shape.
    # The subclass inherits the shim without owning a record, so the message has to come from the ancestor's.
    it "names the base class for a subclass of the action that deferred" do
      action = Class.new(Class.new(named_parent) { include Axn })

      expect { action.class_eval { expects :log } }.to raise_error(
        Axn::ContractViolation::ReservedAttributeError, /ApplicationService/
      )
    end

    it "still surrenders a name axn owns outright" do
      action = Class.new(named_parent) do
        include Axn
        expects :info
        def call = nil
      end

      expect(action.call(info: "x")).to be_ok
    end
  end

  # An `undef_method` above the action takes the name away from every class below it, so there is nothing there
  # for axn to step aside for. Axn keeps its own helper — the answer it gave before it deferred to anything —
  # rather than handing the name to an implementation the undef removed.
  describe "a name an ancestor undefined" do
    let(:barrier) do
      distant = Class.new { def log(*) = "DISTANT-LOG" }
      Class.new(distant) { undef_method :log }
    end

    it "keeps axn's own helper rather than resurrecting the removed implementation" do
      action = Class.new(barrier) { include Axn }

      expect(described_class.definers(action)).to be_empty
      expect(Axn::Internal::NameOwnership.owner_of(action, :log)).to eq(Axn::Core::Logging::InstanceMethods)
    end

    # The same barrier on a name axn cannot surrender: there is no inherited `call` to be standing in front of,
    # so refusing would name a conflict the class does not have.
    it "runs an action whose inherited call the barrier removed" do
      distant = Class.new { def call = :distant }
      unreachable_call = Class.new(distant) { undef_method :call }

      expect(Class.new(unreachable_call) { include Axn }.call).to be_ok
    end

    # A barrier an ancestor gains AFTER `include Axn` is outside the record the include took, so the live read
    # over the walked slice is the only one that sees it. Refusing here would name a `#call` no dispatch can
    # reach and block a class Ruby itself has no complaint about.
    it "runs an action whose inherited call an ancestor undefined AFTER the include" do
      distant = Class.new { def call = :distant }
      barrier = Class.new(distant)
      action = Class.new(barrier) { include Axn }

      barrier.send(:undef_method, :call)

      expect { Class.new(barrier).new.call }.to raise_error(NoMethodError)
      expect(action.call).to be_ok
    end

    # The honest limit of that timing on a DEFERRABLE name, which the live read does not extend: `include Axn`
    # captured the implementation and installed the wrapper while the name was still reachable, so a later undef
    # cannot retract it — the same rule as "a definer reopened after the class is defined is silently ignored".
    # The undef takes the name away from every OTHER class below the barrier; the action keeps what it captured.
    it "keeps the wrapper it already installed when an ancestor undefines a deferrable name AFTER the include" do
      distant = Class.new { def log(*) = "DISTANT-LOG" }
      barrier = Class.new(distant)
      action = Class.new(barrier) { include Axn }

      barrier.send(:undef_method, :log)

      expect { Class.new(barrier).new.log }.to raise_error(NoMethodError)
      expect(described_class.definers(action)).to eq({ log: distant })
      expect(action.send(:new).log("x")).to eq("DISTANT-LOG")
    end

    # A module hosts the barrier just as a class does, and the walk over the action's ancestry meets it either
    # way — but WHERE it is included decides whether the walk visits it at all. With a class in between, the
    # module sits above that class in the ancestry and inside the walked slice.
    it "keeps axn's helper when a module included into an ANCESTOR carries the barrier" do
      distant = Class.new { def log(*) = "DISTANT-LOG" }
      undeffer = Module.new do
        def log(*) = "MOD-LOG"
        undef_method :log
      end
      via_class = Class.new(distant) { include undeffer }

      expect { via_class.new.log }.to raise_error(NoMethodError)
      expect(described_class.definers(Class.new(via_class) { include Axn })).to be_empty
    end

    # Included into the action class ITSELF, the same module is inside the slice the walk excludes along with
    # `base`, so nothing the walk can see reports the barrier — only a lookup taken before `include Axn` masks
    # the chain with axn's own helper does.
    it "keeps axn's helper when a module included into the class ITSELF carries the barrier" do
      distant = Class.new { def log(*) = "DISTANT-LOG" }
      undeffer = Module.new do
        def log(*) = "MOD-LOG"
        undef_method :log
      end
      action = Class.new(distant) do
        include undeffer
        include Axn
      end

      expect { Class.new(distant) { include undeffer }.new.log }.to raise_error(NoMethodError)
      expect(described_class.definers(action)).to be_empty
      expect(Axn::Internal::NameOwnership.owner_of(action, :log)).to eq(Axn::Core::Logging::InstanceMethods)
    end

    # Falls out of reading the barrier off the class's own chain, which sees an undef in the class body as
    # readily as one further up. Left unaddressed before this, because the walk excludes the class itself:
    # `include Axn` handed the name straight back to the implementation the class had just removed.
    it "keeps axn's helper when the class's OWN body removed the inherited implementation" do
      distant = Class.new { def log(*) = "DISTANT-LOG" }
      action = Class.new(distant) do
        undef_method :log
        include Axn
      end

      # The class's own undef entry outranks everything `include Axn` adds, so it takes axn's helper away too —
      # which is what the class asked for. What it no longer does is hand the name back to the implementation
      # the class had just removed.
      expect(described_class.definers(action)).to be_empty
      expect { action.send(:new).log("x") }.to raise_error(NoMethodError)
    end

    # The unsurrenderable half of the same shape. A refusal here would name an inherited `call` the class cannot
    # reach and block a class Ruby itself has no complaint about.
    it "runs an action whose own included module removed the inherited call" do
      distant = Class.new { def call = :distant }
      undeffer = Module.new do
        def call = :mod
        undef_method :call
      end
      action = Class.new(distant) do
        include undeffer
        include Axn
      end

      expect { Class.new(distant) { include undeffer }.new.call }.to raise_error(NoMethodError)
      expect(action.call).to be_ok
    end
  end

  describe "a name axn cannot yield" do
    let(:service_base) do
      stub_const("ServiceBase", Class.new do
        def initialize(user: nil) = @user = user
        def call = :parent_call_ran
      end)
      ServiceBase
    end

    it "raises rather than reporting success for a call that never ran" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(
        Axn::ContractViolation::UnsurrenderableInheritedMethod, /ServiceBase.*#call/m
      )
    end

    it "raises for an inherited initialize, whose absence would leave the parent's state unset" do
      action = Class.new(service_base) do
        include Axn
        def call = nil
      end

      expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod, /#initialize/)
    end

    # The barrier record is taken at include time, so it says nothing about a name the chain gained afterwards —
    # and must not: recording every name the chain could not reach would silently exempt this one, where the
    # live walk is the honest reader and the shadowing is real.
    it "still refuses a superclass reopened to add #call after the include" do
      parent = Class.new
      action = Class.new(parent) { include Axn }
      parent.class_eval { def call = :parent_call_ran }

      expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod, /#call/)
    end

    it "explains the fix" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(/compose|define .*in this class|rename/i)
    end

    # The ACTION is the one class in this message read by DISPATCH. Axn installs a `name` of its own on the
    # classes it builds, so the bound reader that keeps a foreign `to_s` out of the OWNER's slot answers here
    # with the object address axn's own name was put there to replace.
    it "names a factory-built action as axn named it" do
      built = Axn::Factory.build(superclass: service_base) { nil }

      expect { built.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod) do |error|
        expect(error.message).to include(built.name)
        expect(error.message).not_to include("#<Class:0x")
      end
    end

    it "names a class the user wrote by its own constant" do
      stub_const("ChargeCard", Class.new(service_base) { include Axn })

      expect { ChargeCard.call }.to raise_error(/which ChargeCard cannot inherit/)
    end

    # Dispatching the name runs the class's own code while the refusal is being composed, and the refusal is
    # what the caller has to end up with. `Exception` rather than a StandardError because that is the raise a
    # narrower guard would let through, carrying the class's answer out in place of this failure. Stubbed for
    # the example rather than defined on the class, so the reader is back to normal by the time anything else
    # asks this class its name.
    it "falls back rather than letting the class's own name reader replace the refusal" do
      action = Class.new(service_base) { include Axn }
      allow(action).to receive(:name).and_raise(Exception, "the class answered")

      expect { action.call }.to raise_error(
        Axn::ContractViolation::UnsurrenderableInheritedMethod, /which Action cannot inherit/
      )
    end

    # The two remedies are not interchangeable, and a message that blurs them sends the reader back to the bug:
    # `def call = super` on the action reaches axn's default, not the parent's, and reports success exactly as
    # before. So the message has to say which branch keeps the parent's implementation running.
    it "does not let the two remedies read as one" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod) do |error|
        expect(error.message).to include("reaches axn's default, not ServiceBase's")
        expect(error.message).to include("to keep ServiceBase's #call running, compose ServiceBase in")
      end
    end

    # The runtime fact the message asserts, and the sentence an author will act on: `super` from the action's own
    # `call` reaches axn's default, NOT the parent's implementation. Which is why the message names composition
    # as the branch that keeps the parent's `call` running, and this one as the branch that replaces it.
    it "reaches axn's default from super rather than the inherited implementation" do
      ran = []
      base = Class.new { define_method(:call) { ran << :parent_call_ran } }
      action = Class.new(base) do
        include Axn
        # Not useless: this bare `super` is the literal shape the error message describes, and where it lands
        # is the fact under test.
        def call = super # rubocop:disable Lint/UselessMethodDefinition
      end

      expect(action.call).to be_ok
      expect(ran).to be_empty
    end

    it "does not raise when the class defines the name itself" do
      action = Class.new(service_base) do
        include Axn
        def initialize(**) = super()
        def call = nil
      end

      expect(action.call).to be_ok
    end

    it "does not raise for a factory-built class that defines call after the include" do
      base = Class.new { def call = :parent_call_ran }
      built = Axn::Factory.build(-> { 42 }, superclass: base, expose_return_as: :out)

      expect(built.call).to be_ok
      expect(built.call.out).to eq(42)
    end

    # The factory defines `call` on the built class but never `initialize`, so a superclass owning one is refused
    # like any other: the parent's initializer genuinely would not run.
    it "still raises for a factory-built class whose superclass owns initialize" do
      base = Class.new { def initialize(user: nil) = @user = user }
      built = Axn::Factory.build(-> { 42 }, superclass: base, expose_return_as: :out)

      expect { built.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod, /#initialize/)
    end

    it "propagates out of .call rather than settling into a result, since there is no action yet" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod)
      expect { action.call! }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod)
    end

    # An exact count, not a ceiling: this fixture reaches `inherited_definer` once per unmemoized check (its own
    # `call`/`initialize` are answered by `core_definition_answers?` and never get that far), so a ceiling of
    # three would be met by a guard that re-walked on every call.
    it "checks once per class" do
      action = Class.new(service_base) do
        include Axn
        def initialize(**) = super()
        def call = nil
      end
      allow(Axn::Core::MethodShadowing).to receive(:inherited_definer).and_call_original

      3.times { action.call }
      expect(Axn::Core::MethodShadowing).to have_received(:inherited_definer).once
    end

    # The memo is a class-level ivar, which a subclass does not inherit. Pinned by instrumentation because no
    # subclass of a PASSING action can be made to fail — the parent's own definition is inherited along with the
    # verdict — so what needs proving is that the subclass asks the question again rather than what it answers.
    it "re-checks a subclass, which inherits no verdict from the class it descends from" do
      action = Class.new(service_base) do
        include Axn
        def initialize(**) = super()
        def call = nil
      end
      action.call
      subclass = Class.new(action)
      allow(Axn::Core::MethodShadowing).to receive(:core_definition_answers?).and_call_original

      expect(subclass.call).to be_ok
      expect(Axn::Core::MethodShadowing).to have_received(:core_definition_answers?).exactly(3).times
    end

    # The memo is set only after the loop clears, so a refused class stays refused. Set before it, every caller
    # after the first would get the silent success back.
    it "raises again on a second call rather than going quiet after the first" do
      action = Class.new(service_base) { include Axn }

      2.times do
        expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod)
      end
    end

    it "leaves an ordinary action untouched" do
      action = Class.new do
        include Axn
        def call = nil
      end

      expect(action.call).to be_ok
    end

    # Mounting reaches for the target's whole hierarchy by default (`inherit: :lifecycle`) to carry its hooks,
    # callbacks and async config, so any target with an `#initialize` — an ordinary PORO here, the Rails
    # hierarchies in spec_rails — puts an inherited one in front of a class the user never wrote. Both remedies
    # the refusal offers are addressed to the author of the `class X < Y`, and there is none.
    describe "on a class axn built for mounting" do
      let(:target) do
        stub_const("MountTarget", Class.new do
          def initialize(record = nil) = @record = record
          include Axn::Mountable
        end)
      end

      it "runs a mounted axn whose target defines initialize" do
        target.mount_axn(:build, exposes: [:built]) { expose(:built, true) }

        expect(target.build.built).to be(true)
      end

      it "runs a mounted method whose target defines initialize" do
        target.mount_axn_method(:rename) { "renamed" }

        expect(target.rename!).to eq("renamed")
      end

      # `step` defaults to `inherit: :none`, so its superclass is `Object` and the guard has nothing to find —
      # asserted rather than assumed, since the default is what keeps steps out of this entirely. A step that
      # opts into inheriting is built the same way as the other two and is exempt on the same grounds.
      it "leaves a step on Object, and runs one that opts into the target's hierarchy" do
        target.step(:check) { nil }
        target.step(:deep, inherit: :lifecycle) { nil }

        expect(target::Axns::Check.superclass).to eq(Object)
        expect(target::Axns::Check.call).to be_ok
        expect(target::Axns::Deep.call).to be_ok
      end

      it "still refuses a class the user wrote under the same superclass" do
        action = Class.new(target) { include Axn }

        expect { action.call }.to raise_error(
          Axn::ContractViolation::UnsurrenderableInheritedMethod, /MountTarget defines #initialize/
        )
      end

      # The exemption is the absence of an authored decision, so a mount that names its own `superclass:` keeps
      # the refusal: that author chose the edge and can compose the class in instead.
      it "still refuses a mount that names its own superclass" do
        target.mount_axn(:build, superclass: Class.new { def initialize(*) = nil }) { nil }

        expect { target.build }.to raise_error(
          Axn::ContractViolation::UnsurrenderableInheritedMethod, /#initialize/
        )
      end

      it "still refuses an action class the user wrote and then mounted" do
        stub_const("PreexistingAction", Class.new(service_base) { include Axn })
        target.mount_axn(:preexisting, PreexistingAction)

        expect { target.preexisting }.to raise_error(
          Axn::ContractViolation::UnsurrenderableInheritedMethod, /ServiceBase defines #call/
        )
      end
    end
  end

  describe "the warning" do
    let(:warnings) { [] }

    before do
      logger = instance_double(Logger)
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
      allow(Axn.config).to receive(:logger).and_return(logger)
      described_class.send(:_reset_warned_for_specs!)
    end

    # Bound to its constant before the include, the way `class ChargeCard < ApplicationService` binds it before
    # the body runs: the class has to know its own name by the time the warning names it.
    it "names the class, the owner, the name, and both ways to resolve it" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      stub_const("ChargeCard", Class.new(ApplicationService))
      ChargeCard.class_eval { include Axn }
      ChargeCard.call

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include("ChargeCard", "ApplicationService", "log", "prefer_inherited", "prefer_axn")
    end

    # Announced when the action RUNS, not when it is defined: the remedies the message names are declarations in
    # the class body, which only runs after the include, so a warning written during the include would be one no
    # author could answer.
    it "says nothing until the class is run" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      action = Class.new(ApplicationService) { include Axn }
      expect(warnings).to be_empty

      action.call
      expect(warnings.size).to eq(1)
    end

    # The class the line is addressed TO is named by dispatch, for the reason the refusal names it that way:
    # a mounted axn's name is one axn installed, and the bound reader answers with its host's object address
    # instead. The DEFINER stays bound — it is a class the user wrote, and axn never renames those.
    it "names a mounted axn as axn named it, rather than by its anonymous host's address" do
      host = Class.new do
        def log(*) = nil
        include Axn::Mountable
      end
      host.mount_axn(:build) { nil }
      host.build

      expect(warnings.size).to eq(1)
      expect(warnings.first).to start_with("[#{host::Axns::Build.name}]")
    end

    it "names a factory-built action as axn named it" do
      built = Axn::Factory.build(superclass: Class.new { def log(*) = nil }) { nil }
      built.call

      expect(warnings.size).to eq(1)
      expect(warnings.first).to start_with("[#{built.name}]")
    end

    it "warns once per definer method however many classes inherit it" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      3.times { Class.new(ApplicationService) { include Axn }.call }

      expect(warnings.size).to eq(1)
    end

    # The other half of the pair key: keyed by name alone, a second hierarchy shadowing a name already
    # announced for the first would be silently swallowed — the case the warning exists for.
    it "warns separately for a second definer of the same name" do
      stub_const("Alpha", Class.new { def log(*) = nil })
      stub_const("Beta", Class.new { def log(*) = nil })
      Class.new(Alpha) { include Axn }.call
      Class.new(Beta) { include Axn }.call

      expect(warnings.size).to eq(2)
    end

    it "warns separately for a second name from the same definer" do
      stub_const("ApplicationService", Class.new do
        def log(*) = nil
        def info(*) = nil
      end)
      Class.new(ApplicationService) { include Axn }.call

      expect(warnings.size).to eq(2)
    end

    it "says nothing when there is no collision" do
      Class.new { include Axn }.call
      expect(warnings).to be_empty
    end

    # Once per class as well as once per definer: the ancestry walk it needs is not something to repeat on every
    # call of a hot action.
    it "announces once however many times the class is run" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      action = Class.new(ApplicationService) { include Axn }
      3.times { action.call }

      expect(warnings.size).to eq(1)
    end

    # A preference is an answer to the warning, so there is nothing left to announce — for the name it names,
    # and for that name only.
    it "says nothing for a name the class put back on axn's implementation" do
      stub_const("ApplicationService", Class.new do
        def log(*) = nil
        def info(*) = nil
      end)
      action = Class.new(ApplicationService) do
        include Axn
        prefer_axn :log
      end
      action.call

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include("#info")
    end

    # The record belongs to the base class and the preference to the subclass, so only the class being RUN can
    # answer what it resolves to.
    it "says nothing for a name a subclass put back on axn's implementation" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      base = Class.new(ApplicationService) { include Axn }
      child = Class.new(base) { prefer_axn :log }
      child.call

      expect(warnings).to be_empty
    end

    # The two shapes the record cannot see: `include Axn` recorded a deferral, and a definition written after it
    # took the name over. Both are what the docs call "not a conflict" — the author's own method wins on its own
    # terms — so a line saying calls reach the parent's version asserts the opposite of what runs, and names two
    # remedies that would change nothing.
    it "says nothing for a name the class defines in its own body" do
      stub_const("ApplicationService", Class.new { def log(*) = :from_parent })
      action = Class.new(ApplicationService) do
        include Axn
        def log(*) = :from_child
      end
      action.call

      expect(action.instance_method(:log).owner).to eq(action)
      expect(warnings).to be_empty
    end

    it "says nothing for a name a module included after the include defines" do
      stub_const("ApplicationService", Class.new { def log(*) = :from_parent })
      overrides = Module.new { def log(*) = :from_module }
      action = Class.new(ApplicationService) do
        include Axn
        include overrides
      end
      action.call

      expect(action.instance_method(:log).owner).to eq(overrides)
      expect(warnings).to be_empty
    end

    # Announced from the execution funnel — before the action is constructed, and outside the executor's own
    # guards — so an unguarded emission would let a broken logger take `.call` down over a courtesy.
    it "does not let a raising logger escape .call" do
      allow(Axn.config.logger).to receive(:warn).and_raise("logger down")
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      action = Class.new(ApplicationService) { include Axn }

      expect(action.call).to be_ok
    end

    # The once-per-definer record is KEYED to the definer, so reaching it dispatches the definer's own `hash` —
    # and a definer is an arbitrary class or module the user wrote. Outside the guard, that turned a courtesy
    # into the action's failure. The first deferral of a process is the case to write, because an empty Hash
    # short-circuits `key?` without hashing and only the STORE reaches the definer.
    it "does not let a definer whose hash raises escape .call" do
      definer = Module.new do
        def log(*) = nil
        def self.hash = raise("hostile hash")
      end
      action = Class.new(Class.new { include definer }) { include Axn }

      expect(action.call).to be_ok
      # The announcement is abandoned rather than emitted, and reported through the ignored-exception channel
      # like any other side-channel escape.
      expect(warnings.grep(/prefer_inherited/)).to be_empty
      expect(warnings.grep(/IGNORING EXCEPTION.*hostile hash/m)).not_to be_empty
    end

    # Guarding the whole announcement must not reorder it: the record still goes in before the line is written,
    # so a logger that raises on the first action cannot leave the deferral unrecorded and let the next one
    # inheriting the same method announce it again.
    it "records the deferral even when the emission raises" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      allow(Axn.config.logger).to receive(:warn).and_raise("logger down")
      Class.new(ApplicationService) { include Axn }.call

      allow(Axn.config.logger).to receive(:warn) { |msg| warnings << msg }
      Class.new(ApplicationService) { include Axn }.call

      expect(warnings.grep(/prefer_inherited/)).to be_empty
    end

    # The record is of a side effect already committed, so no reset re-arms it — including the one that
    # deliberately DOES re-arm axn's other once-per-process warning.
    it "does not re-announce a deferral after a suite-level reset" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      Class.new(ApplicationService) { include Axn }.call
      expect(warnings.size).to eq(1)

      Axn::Testing.reset!
      logger = instance_double(Logger, info: nil, debug: nil)
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)
      Class.new(ApplicationService) { include Axn }.call

      expect(warnings.size).to eq(1)
    end
  end

  describe "prefer_axn" do
    let(:parent) do
      Class.new do
        def fail!(msg) = raise(ArgumentError, "PARENT-FAIL #{msg}")
        def log(*) = "PARENT-LOG"
      end
    end

    it "restores axn's implementation and its semantics" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :fail!
        def call = fail!("declined")
      end

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("declined")
    end

    # The point of restoring the canonical OWNER rather than some wrapper of axn's: a field declaration asks who
    # owns the name, and anything but axn's own module is refused as "not axn's to surrender".
    it "restores the canonical owner, so a declaration may surrender the name again" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :fail!
      end

      expect(Axn::Internal::NameOwnership.owner_of(action, :fail!)).to eq(Axn::Core)
      expect(Axn::Internal::NameOwnership.conflict_for(action, :fail!)).to be_nil
    end

    it "leaves the other deferrals on the class intact" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :fail!
      end

      expect(action.send(:new).log).to eq("PARENT-LOG")
      expect(described_class.definers(action)[:log]).to eq(parent)
    end

    it "is a satisfied assertion when nothing was deferred" do
      action = Class.new do
        include Axn
        prefer_axn :log
      end

      expect(described_class.shim(action)).to be_nil
      expect(Axn::Internal::NameOwnership.owner_of(action, :log)).to eq(Axn::Core::Logging::InstanceMethods)
    end
  end

  # The ordinary Rails arrangement: one base class includes Axn (and so owns the deferral record), and every
  # action is a subclass of it. A declaration on the subclass must deliver its own outcome without touching a
  # record it does not own -- editing the inherited shim would rewrite the base class and every sibling.
  describe "a declaration on a subclass of the class that deferred" do
    before do
      stub_const("ApplicationService", Class.new do
        def fail!(msg) = raise(ArgumentError, "PARENT-FAIL #{msg}")
        def log(*) = "PARENT-LOG"
      end)
      stub_const("ApplicationAction", Class.new(ApplicationService) { include Axn })
      stub_const("ChargeCard", Class.new(ApplicationAction) do
        prefer_axn :fail!
        def call = fail!("declined")
      end)
      stub_const("SendReceipt", Class.new(ApplicationAction))
    end

    it "gives the declaring class axn's implementation" do
      result = ChargeCard.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("declined")
    end

    it "leaves the parent, which owns the record, running its own inherited implementation" do
      expect { ApplicationAction.send(:new).fail!("x") }.to raise_error(ArgumentError, "PARENT-FAIL x")
      expect(Axn::Internal::NameOwnership.owner_of(ApplicationAction, :fail!)).to eq(ApplicationService)
      expect(described_class.definers(ApplicationAction)).to eq(fail!: ApplicationService, log: ApplicationService)
    end

    it "leaves a sibling running its own inherited implementation" do
      expect { SendReceipt.send(:new).fail!("x") }.to raise_error(ArgumentError, "PARENT-FAIL x")
      expect(Axn::Internal::NameOwnership.owner_of(SendReceipt, :fail!)).to eq(ApplicationService)
    end

    it "leaves the declaring class's other inherited helpers alone" do
      expect(ChargeCard.send(:new).log).to eq("PARENT-LOG")
      expect(Axn::Internal::NameOwnership.owner_of(ChargeCard, :log)).to eq(ApplicationService)
    end

    it "accepts prefer_inherited for a deferral recorded on the parent" do
      expect { ChargeCard.class_eval { prefer_inherited :log } }.not_to raise_error
      expect(ChargeCard.send(:new).log).to eq("PARENT-LOG")
    end
  end

  describe "prefer_inherited" do
    let(:parent) { Class.new { def log(*) = "PARENT-LOG" } }

    it "keeps the inherited implementation and silences the warning" do
      logger = instance_double(Logger, info: nil, debug: nil)
      warnings = []
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)
      described_class.send(:_reset_warned_for_specs!)

      action = Class.new(parent) do
        include Axn
        prefer_inherited :log
        def call = nil
      end

      expect(action.call).to be_ok
      expect(action.send(:new).log).to eq("PARENT-LOG")
      expect(warnings).to be_empty
    end

    # Per name, not per class: acknowledging one deferral says nothing about the others.
    it "leaves the warning standing for a name it did not name" do
      logger = instance_double(Logger, info: nil, debug: nil)
      warnings = []
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)
      described_class.send(:_reset_warned_for_specs!)

      parent_with_two = Class.new do
        def log(*) = "PARENT-LOG"
        def info(*) = "PARENT-INFO"
      end
      action = Class.new(parent_with_two) do
        include Axn
        prefer_inherited :log
        def call = nil
      end
      action.call

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include("#info")
    end

    it "raises when nothing in the hierarchy owns the name" do
      expect do
        Class.new do
          include Axn
          prefer_inherited :log
        end
      end.to raise_error(Axn::ContractViolation, /nothing to prefer/)
    end

    # Named on the same terms as the refusal above: dispatched, so a class axn named answers with that name,
    # and an anonymous one — the common case in a spec — with the fallback rather than with its address.
    it "names an anonymous class by the fallback rather than by its object address" do
      expect do
        Class.new do
          include Axn
          prefer_inherited :log
        end
      end.to raise_error(/surrendered no #log on Action/)
    end

    # The declarations are a pair, so the second one wins rather than reporting the first as an obstacle.
    it "takes the name back from a prefer_axn on the same class" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :log
        prefer_inherited :log
      end

      expect(action.send(:new).log).to eq("PARENT-LOG")
      expect(Axn::Internal::NameOwnership.owner_of(action, :log)).to eq(parent)
    end
  end

  # The other direction of the pair across a hierarchy: the base class chose axn's, one subclass takes the
  # inherited implementation back, and everything else keeps what the base class chose.
  describe "prefer_inherited on a subclass of a class that preferred axn's" do
    before do
      stub_const("ApplicationService", Class.new { def log(*) = "PARENT-LOG" })
      stub_const("ApplicationAction", Class.new(ApplicationService) do
        include Axn
        prefer_axn :log
      end)
      stub_const("ChargeCard", Class.new(ApplicationAction) { prefer_inherited :log })
      stub_const("SendReceipt", Class.new(ApplicationAction))
    end

    it "gives the declaring class the implementation its own hierarchy declares" do
      expect(ChargeCard.send(:new).log).to eq("PARENT-LOG")
      expect(Axn::Internal::NameOwnership.owner_of(ChargeCard, :log)).to eq(ApplicationService)
    end

    it "leaves the parent, which owns the record, on axn's implementation" do
      expect(Axn::Internal::NameOwnership.owner_of(ApplicationAction, :log)).to eq(Axn::Core::Logging::InstanceMethods)
      expect(described_class.definers(ApplicationAction)[:log]).to eq(Axn::Core::Logging::InstanceMethods)
    end

    it "leaves a sibling on axn's implementation" do
      expect(Axn::Internal::NameOwnership.owner_of(SendReceipt, :log)).to eq(Axn::Core::Logging::InstanceMethods)
    end
  end

  # A `def` of the author's own outranks anything axn installs, so the declaration cannot change what answers.
  # What it does change is what `super` from that `def` reaches, which is the only reachable difference — and
  # the reason `prefer_axn` is worth writing beside a wrapper method.
  describe "prefer_axn beside a definition of the class's own" do
    it "redirects super from the class's own def to axn's implementation" do
      parent = Class.new { def fail!(msg) = raise(ArgumentError, "PARENT-FAIL #{msg}") }
      action = Class.new(parent) do
        include Axn
        def fail!(msg) = super("wrapped: #{msg}")
        prefer_axn :fail!
        def call = fail!("declined")
      end

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("wrapped: declined")
    end

    # The cost of the same rule on a class that had no deferral to begin with: axn's implementation was already
    # what `super` reached, so the wrapper the declaration installs is a frame that changes nothing. Pinned
    # rather than optimised away, because telling the two apart means asking what would answer BELOW the class's
    # own table — a walk the record exists to avoid.
    it "opens a record even where the declaration changes nothing" do
      action = Class.new do
        include Axn
        def log(*) = "MINE"
        prefer_axn :log
      end

      expect(action.send(:new).log).to eq("MINE")
      expect(described_class.definers(action)).to eq(log: Axn::Core::Logging::InstanceMethods)
    end
  end

  describe "the guard on both declarations" do
    %i[call _run initialize].each do |name|
      it "refuses #{name}, which axn dispatches to run the action" do
        expect do
          Class.new do
            include Axn
            prefer_inherited name
          end
        end.to raise_error(Axn::ContractViolation, /axn itself/)

        expect do
          Class.new do
            include Axn
            prefer_axn name
          end
        end.to raise_error(Axn::ContractViolation, /axn itself/)
      end
    end

    it "refuses ambient_context, a sentinel rather than a convenience" do
      expect do
        Class.new do
          include Axn
          prefer_axn :ambient_context
        end
      end.to raise_error(Axn::ContractViolation, /AmbientContext/)
    end

    it "refuses a Ruby-owned name" do
      expect do
        Class.new do
          include Axn
          prefer_axn :inspect
        end
      end.to raise_error(Axn::ContractViolation, /Kernel|Object/)
    end

    it "refuses an axn internal" do
      expect do
        Class.new do
          include Axn
          prefer_axn :_forward_to_class
        end
      end.to raise_error(Axn::ContractViolation, /internals/)
    end

    # `conflict_for` reports a name no one owns as free, which is not the same verdict as "axn will hand this
    # over": axn has no implementation to choose, so neither declaration means anything.
    it "refuses a name axn does not define at all" do
      expect do
        Class.new do
          include Axn
          prefer_axn :perform_later
        end
      end.to raise_error(Axn::ContractViolation, /public instance surface/)
    end

    it "refuses a private axn helper, which is not a surface anyone can stand in for" do
      expect do
        Class.new do
          include Axn
          prefer_inherited :internal_context
        end
      end.to raise_error(Axn::ContractViolation, /public instance surface/)
    end
  end
end
