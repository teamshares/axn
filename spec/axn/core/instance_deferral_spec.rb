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
  # would strip the helper from every class beneath it. `nearest_record` is the read that walks instead.
  it "records nothing on a subclass of a class that did defer" do
    parent_action = Class.new(parent) { include Axn }
    child = Class.new(parent_action)

    expect(described_class.definers(child)).to be_empty
    expect(described_class.shim(child)).to be_nil
    expect(described_class.nearest_record(child)).to eq(described_class.nearest_record(parent_action))
    expect(described_class.nearest_record(child)[:definers]).to eq(log: parent, info: parent)
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

    it "explains the fix" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(/compose|define .*in this class|rename/i)
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

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include("ChargeCard", "ApplicationService", "log", "prefer_inherited", "prefer_axn")
    end

    it "warns once per definer method however many classes inherit it" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      3.times { Class.new(ApplicationService) { include Axn } }

      expect(warnings.size).to eq(1)
    end

    it "warns separately for a second name from the same definer" do
      stub_const("ApplicationService", Class.new do
        def log(*) = nil
        def info(*) = nil
      end)
      Class.new(ApplicationService) { include Axn }

      expect(warnings.size).to eq(2)
    end

    it "says nothing when there is no collision" do
      Class.new { include Axn }
      expect(warnings).to be_empty
    end

    # The record is of a side effect already committed, so no reset re-arms it — including the one that
    # deliberately DOES re-arm axn's other once-per-process warning.
    it "does not re-announce a deferral after a suite-level reset" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      Class.new(ApplicationService) { include Axn }
      expect(warnings.size).to eq(1)

      Axn::Testing.reset!
      logger = instance_double(Logger, info: nil, debug: nil)
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)
      Class.new(ApplicationService) { include Axn }

      expect(warnings.size).to eq(1)
    end
  end
end
