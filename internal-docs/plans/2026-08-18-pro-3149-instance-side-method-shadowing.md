# Instance-side method shadowing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a name the user's own hierarchy already owns win over axn's instance-side helper — the counterpart of the class-side deferral `Axn::Core::MethodShadowing` already performs — and raise loudly for the three names axn cannot yield instead of silently swallowing them.

**Architecture:** One private ancestry walk serves both receivers: the class side keeps asking it about `base.singleton_class`, the instance side asks it about `base.ancestors` truncated at `::Object` and excluding `base` itself. When it finds a definer for one of the 17 surrenderable sugar names, `include Axn` installs a single per-class anonymous module holding a `bind_call` wrapper around the definer's `UnboundMethod` — included last, so it outranks axn's own modules — and records the definer so `NameOwnership` can name it in a declaration error. For `call`, `_run` and `initialize` deferral is impossible, so a per-class assertion at the one execution funnel (`Core::ClassMethods#call`) raises instead.

**Tech Stack:** Ruby 3.2+, RSpec. No new dependencies.

**Spec:** `internal-docs/specs/2026-08-18-instance-side-method-shadowing-design.md`

## Global Constraints

- **Non-Rails safe.** Guard any AR/Rails reference with `defined?()`. Specs live in `spec/` (plain POROs); add `spec_rails/` coverage only if a Rails-path difference appears.
- **Derived, never listed.** No new constant enumerating method names. The deferrable surface comes from `Axn::Internal::NameOwnership::SURRENDERABLE_OWNERS`; the refusals come from `NameOwnership.conflict_for` / `UNSURRENDERABLE`. A reviewer seeing a literal name array in this work should reject it.
- **Reflection reads go through `Axn::Internal::NativeMethods`.** Never `mod.ancestors`, `mod.instance_method`, `mod.instance_methods`, `mod.method_defined?`, `obj.singleton_class` directly — `spec/axn/internal/no_unbound_module_reflection_spec.rb` fails the build. Establish the receiver is a Module via `Internal::Identity.kind?(mod, ::Module)` first, and use `Internal::Identity.same?` in place of `==` for module identity.
- **Installing onto a caller's class is also a bound call.** `include` / `define_method` / `remove_method` reached on a user's class or module go through new `NativeMethods` helpers, following the precedent `NativeMethods.prepend_module` sets: an installation that silently declines leaves a guard uninstalled.
- **Comments explain *why*, not *what*.** No historical narration ("used to X, now Y"), no ticket references in code comments, no internal taxonomy labels.
- **Every new message explains the problem AND the fix**, per `lib/axn/exceptions.rb`'s bar (see `UnknownExposure`).
- **CHANGELOG every user-visible change** under the unreleased version heading, tagged `[BREAKING]` / `[BUGFIX]` / `[INTERNAL]`.
- Run `bundle exec rspec` (full suite) before the final commit of each task, not just the new file — `spec/axn/internal/no_shadowable_dispatch_spec.rb`, `no_unbound_module_reflection_spec.rb` and `spec/axn/core/method_shadowing_integrity_spec.rb` all police this area.

---

### Task 1: One walk, two receivers

**Files:**
- Modify: `lib/axn/core/method_shadowing.rb`
- Test: `spec/axn/core/method_shadowing_spec.rb` (create)

**Interfaces:**
- Consumes: `NativeMethods.module_ancestors`, `.declares_own_instance_method?`, `.declared_module_name`, `Internal::Identity.same?`
- Produces: `MethodShadowing.inherited_definer(base, name) -> Module | nil`; `MethodShadowing.externally_defined?(base, name) -> Boolean` (unchanged signature and behaviour)

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/method_shadowing_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Core::MethodShadowing do
  let(:base) do
    Class.new do
      def log(*) = "PARENT"
    end
  end

  describe ".inherited_definer" do
    it "names an ancestor that declares the name" do
      child = Class.new(base)
      expect(described_class.inherited_definer(child, :log)).to eq(base)
    end

    it "names a module included into an ancestor" do
      mod = Module.new { def log(*) = "MOD" }
      base.include(mod)
      expect(described_class.inherited_definer(Class.new(base), :log)).to eq(mod)
    end

    it "names a module included into the class itself" do
      mod = Module.new { def log(*) = "MOD" }
      child = Class.new { include mod }
      expect(described_class.inherited_definer(child, :log)).to eq(mod)
    end

    it "is nil for a name nothing before Object declares" do
      expect(described_class.inherited_definer(Class.new, :log)).to be_nil
    end

    it "is nil for a name only Kernel or Object declares, so axn keeps defining warn" do
      klass = Class.new
      expect(described_class.inherited_definer(klass, :warn)).to be_nil
      expect(described_class.inherited_definer(klass, :inspect)).to be_nil
      expect(described_class.inherited_definer(klass, :hash)).to be_nil
    end

    it "excludes the class's own definition, so a def in the class body is not a deferral target" do
      klass = Class.new { def log(*) = "OWN" }
      expect(described_class.inherited_definer(klass, :log)).to be_nil
    end

    it "excludes a module prepended to the class, which already outranks anything axn installs" do
      mod = Module.new { def log(*) = "PRE" }
      klass = Class.new { prepend mod }
      expect(described_class.inherited_definer(klass, :log)).to be_nil
    end

    it "ignores axn's own core modules, so an action class is not its own definer" do
      action = Class.new { include Axn }
      expect(described_class.inherited_definer(action, :log)).to be_nil
      expect(described_class.inherited_definer(action, :fail!)).to be_nil
    end

    it "counts a satellite axn namespace as external, matching the class-side rule" do
      satellite = Module.new { def log(*) = "MCP" }
      stub_const("Axn::Fake::Sugar", satellite)
      expect(described_class.inherited_definer(Class.new { include satellite }, :log)).to eq(satellite)
    end

    it "finds a private definition, which shadows as completely as a public one" do
      base.send(:private, :log)
      expect(described_class.inherited_definer(Class.new(base), :log)).to eq(base)
    end
  end

  describe ".externally_defined?" do
    it "still answers the class-side question" do
      parent = Class.new { def self.description = "PARENT" }
      expect(described_class.externally_defined?(Class.new(parent), :description)).to be true
      expect(described_class.externally_defined?(Class.new, :description)).to be false
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/method_shadowing_spec.rb`
Expected: FAIL — `undefined method 'inherited_definer' for module Axn::Core::MethodShadowing`. The two `.externally_defined?` examples pass already.

- [ ] **Step 3: Extract the shared walk and add the instance-side query**

In `lib/axn/core/method_shadowing.rb`, replace the body of `externally_defined?` and add the instance-side entry point. Keep `KERNEL_SINGLETON_CLASS` and `_axn_core_owned?` as they are.

```ruby
      def externally_defined?(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(KERNEL_SINGLETON_CLASS.bind_call(base))
        !_external_definer(ancestry, name).nil?
      end

      # The instance-side counterpart, and the module that stands in the way rather than a boolean, because the
      # caller both defers to it and names it in an error. Two things differ from the class-side walk above, and
      # both are about what counts as "the user's own":
      #
      # Truncated at ::Object, because everything from there outward is Ruby's. `Kernel` owns `warn` and `Object`
      # owns `inspect`/`hash`/`then`/`tap`, so an untruncated walk would make axn permanently decline to define
      # `warn` and silently redirect every `warn("msg")` inside an action to stderr instead of the logger.
      #
      # `base` itself is excluded (along with anything prepended to it, which already outranks whatever axn
      # installs). A `def log` in the class body is the user's own method and wins on its own terms, with `super`
      # reaching axn's — treating it as a deferral target would point the deferral at the very method it defers.
      def inherited_definer(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(base)
        above_base = ancestry.drop_while { |mod| !Axn::Internal::Identity.same?(mod, base) }.drop(1)
        _external_definer(above_base.take_while { |mod| !Axn::Internal::Identity.same?(mod, ::Object) }, name)
      end

      # The first module in `ancestry` that declares `name` in its OWN table, skipping axn core's. Own table
      # rather than effective lookup: the question is who would be shadowed, and a prepend elsewhere in the
      # chain does not make a declaration disappear.
      def _external_definer(ancestry, name)
        ancestry.find do |mod|
          next false if _axn_core_owned?(mod)

          Axn::Internal::NativeMethods.declares_own_instance_method?(mod, name)
        end
      end
      private_class_method :_external_definer
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/core/method_shadowing_spec.rb spec/axn/core/include_shadowing_spec.rb`
Expected: PASS (all of both files).

- [ ] **Step 5: Full suite, then commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/method_shadowing.rb spec/axn/core/method_shadowing_spec.rb
git commit -m "PRO-3149: ask the shadowing walk about the instance side too"
```

---

### Task 2: The deferrable surface, derived from SURRENDERABLE_OWNERS

**Files:**
- Modify: `lib/axn/internal/native_methods.rb`
- Modify: `lib/axn/core/method_shadowing.rb`
- Test: `spec/axn/core/method_shadowing_spec.rb`, `spec/axn/internal/native_methods_spec.rb`

**Interfaces:**
- Produces: `NativeMethods.own_public_instance_methods(mod) -> Array<Symbol>`; `MethodShadowing.deferrable_names -> Array<Symbol>` (frozen, memoized)

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/internal/native_methods_spec.rb`:

```ruby
  describe ".own_public_instance_methods" do
    it "lists only the module's own public methods" do
      parent = Module.new { def inherited_one = nil }
      mod = Module.new do
        include parent
        def public_one = nil
        private def private_one = nil
      end

      expect(described_class.own_public_instance_methods(mod)).to eq([:public_one])
    end

    it "reads the table natively rather than dispatching" do
      mod = Module.new do
        def self.instance_methods(*) = raise("hijacked")
        def public_one = nil
      end

      expect(described_class.own_public_instance_methods(mod)).to eq([:public_one])
    end
  end
```

Append to `spec/axn/core/method_shadowing_spec.rb`:

```ruby
  describe ".deferrable_names" do
    subject(:names) { described_class.deferrable_names }

    it "is every public helper axn's surrenderable modules own" do
      expect(names).to include(:fail!, :done!, :forward!)
      expect(names).to include(:result, :inputs, :expose, :default_error, :default_success)
      expect(names).to include(:execution_context, :set_execution_context, :clear_execution_context)
      expect(names).to include(:log, :debug, :info, :warn, :error, :fatal)
      expect(names.size).to eq(17)
    end

    it "is derived from SURRENDERABLE_OWNERS rather than listed" do
      derived = Axn::Internal::NameOwnership::SURRENDERABLE_OWNERS.flat_map do |mod|
        Axn::Internal::NativeMethods.own_public_instance_methods(mod)
      end
      expect(names).to match_array(derived.reject { |n| n.to_s.start_with?("_") }.uniq)
    end

    it "excludes the names axn dispatches on itself" do
      expect(names).not_to include(:call, :_run, :initialize)
      expect(names).not_to include(:_forward_to_class, :_propagate_sub_result_outcome!)
    end

    it "excludes ambient_context, which is a sentinel rather than a convenience" do
      expect(names).not_to include(:ambient_context)
    end

    it "excludes private helpers, which are not a surface a user calls" do
      expect(names).not_to include(:internal_context, :inputs_for_logging, :outputs_for_logging)
    end

    it "is frozen and memoized" do
      expect(names).to be_frozen
      expect(described_class.deferrable_names).to be(names)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/method_shadowing_spec.rb -e deferrable_names spec/axn/internal/native_methods_spec.rb -e own_public_instance_methods`
Expected: FAIL — `undefined method 'own_public_instance_methods'` / `'deferrable_names'`.

- [ ] **Step 3: Add the native reader**

In `lib/axn/internal/native_methods.rb`, beside `declares_own_instance_method?`:

```ruby
      # A module's OWN public instance methods, read natively. Same Module precondition as the readers above.
      # Public only: a private helper is not a surface a caller dispatches, so it is not a surface axn hands to
      # anyone else either.
      def self.own_public_instance_methods(mod) = MODULE_PUBLIC_INSTANCE_METHODS.bind_call(mod, false)
```

and add the constant beside its siblings (keep the alphabetical grouping):

```ruby
      MODULE_PUBLIC_INSTANCE_METHODS = ::Module.instance_method(:public_instance_methods)
```

- [ ] **Step 4: Add the derived surface**

In `lib/axn/core/method_shadowing.rb`. Define it with an explicit `self.` receiver rather than inside the `module_function` block: `module_function` would also stamp a private instance copy onto every action, and the memo ivar would then land on the action instead of the module.

```ruby
      # The instance-side names axn will hand to a user's own hierarchy: the public helpers its surrenderable
      # modules own, minus the internals a leading underscore marks. Both halves are NameOwnership's answers, not
      # a second opinion — a name a declaration may take is a name a superclass may take, and deriving from the
      # same source is what keeps the two from drifting.
      #
      # Computed on first use, not at load: this file is required before the modules it asks about.
      def self.deferrable_names
        @deferrable_names ||= Axn::Internal::NameOwnership::SURRENDERABLE_OWNERS.flat_map do |mod|
          Axn::Internal::NativeMethods.own_public_instance_methods(mod)
        end.reject { |name| Axn::Internal::NameOwnership.internal_name?(name) }.uniq.freeze
      end
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/axn/core/method_shadowing_spec.rb spec/axn/internal/native_methods_spec.rb`
Expected: PASS. If the count assertion fails, do **not** edit the expectation to match — a surface that grew means a sugar module gained a public helper, so confirm that is intended and update the count in the same commit as the change that caused it.

- [ ] **Step 6: Full suite, then commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/internal/native_methods.rb lib/axn/core/method_shadowing.rb spec/axn/core/method_shadowing_spec.rb spec/axn/internal/native_methods_spec.rb
git commit -m "PRO-3149: derive the deferrable surface from the surrenderable owners"
```

---

### Task 3: Install the deferral shim at include time

**Files:**
- Create: `lib/axn/core/instance_deferral.rb`
- Modify: `lib/axn/core.rb` (add the require), `lib/axn.rb` (`Axn.included`)
- Modify: `lib/axn/internal/native_methods.rb` (bound install helpers)
- Test: `spec/axn/core/instance_deferral_spec.rb` (create)

**Interfaces:**
- Consumes: `MethodShadowing.deferrable_names`, `MethodShadowing.inherited_definer`
- Produces:
  - `NativeMethods.include_module(mod, other) -> mod`
  - `NativeMethods.define_own_instance_method(mod, name, &body) -> Symbol`
  - `Core::InstanceDeferral.install(base) -> Hash{Symbol => Module}` (the definers it deferred to; empty when there was no collision)
  - `Core::InstanceDeferral.definers(klass) -> Hash{Symbol => Module}` (frozen-empty when none)
  - `Core::InstanceDeferral.shim(klass) -> Module | nil`

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/instance_deferral_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Core::InstanceDeferral do
  let(:parent) do
    Class.new do
      def log(msg, **) = "PARENT-LOG(#{msg})"
      def info(msg, **) = "PARENT-INFO(#{msg})"
    end
  end

  it "lets the inherited definition win over axn's helper" do
    action = Class.new(parent) do
      include Axn
      def call = expose_nothing
      def expose_nothing = nil
    end

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
      def log(a, b = nil, *rest, kw: nil, **opts, &blk) = [a, b, rest, kw, opts, blk&.call]
    end
    action = Class.new(base) { include Axn }

    expect(action.send(:new).log(1, 2, 3, kw: 4, other: 5) { 6 }).to eq([1, 2, [3], 4, { other: 5 }, 6])
  end

  it "keeps a Hash passed positionally positional" do
    base = Class.new { def log(payload) = payload }
    action = Class.new(base) { include Axn }

    expect(action.send(:new).log({ level: :warn })).to eq(level: :warn)
  end

  it "lets a class-body def wrap the inherited implementation through super" do
    action = Class.new(parent) do
      include Axn
      def log(msg, **kw) = "WRAPPED[#{super}]"
    end

    expect(action.send(:new).log("x")).to eq("WRAPPED[PARENT-LOG(x)]")
  end

  it "leaves a class-body def written before the include reaching axn's implementation" do
    logged = []
    allow(Axn.config).to receive(:logger).and_return(instance_double(Logger, info: nil).tap { |l|
      allow(l).to receive(:info) { |msg| logged << msg }
    })

    action = Class.new do
      def log(msg, **kw) = super("[wrapped] #{msg}", **kw)
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
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Core::InstanceDeferral`.

- [ ] **Step 3: Add the bound install helpers**

In `lib/axn/internal/native_methods.rb`, beside `prepend_module`, with the constants beside their siblings:

```ruby
      MODULE_DEFINE_METHOD = ::Module.instance_method(:define_method)
      MODULE_INCLUDE = ::Module.instance_method(:include)
      MODULE_REMOVE_METHOD = ::Module.instance_method(:remove_method)
```

```ruby
      # `include`, `define_method` and `remove_method`, bound — for INSTALLING onto a caller's class or onto a
      # module axn hands it, rather than asking a question. Same reasoning as `prepend_module`: a class that
      # defines its own `include` and quietly declines would leave the installation absent, and an absent
      # deferral silently restores the shadowing it was there to remove.
      def self.include_module(mod, other) = MODULE_INCLUDE.bind_call(mod, other)
      def self.define_own_instance_method(mod, name, &body) = MODULE_DEFINE_METHOD.bind_call(mod, name, &body)
      def self.remove_own_instance_method(mod, name) = MODULE_REMOVE_METHOD.bind_call(mod, name)
```

- [ ] **Step 4: Create the deferral module**

Create `lib/axn/core/instance_deferral.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Core
    # `include Axn` puts axn's user-facing helpers in modules included into the user's class, and Ruby places
    # those above the superclass — so an `ApplicationService#log` would lose to axn's with nothing said. Where
    # the user's own hierarchy already owns one of the surrenderable names, axn steps aside instead.
    #
    # Stepping aside cannot be a non-definition: the sugar modules are shared by every action class, so there is
    # no per-class version of them to leave a name out of. It is instead one anonymous module per colliding
    # class, included last so it outranks axn's, holding a wrapper that `bind_call`s the definer's own
    # UnboundMethod. Classes with no collision get no module and no extra frame.
    module InstanceDeferral
      DEFERRALS_IVAR = :@__axn_instance_deferrals
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      NO_DEFERRALS = {}.freeze

      # Bound rather than dispatched, and stored in an ivar rather than a class method, for the same reason the
      # rest of this area is: whatever axn reads back has to be axn's own, on a class whose method table the
      # user owns. An ivar carries no dispatchable name.
      def self.install(base)
        deferrals = _collect(base)
        return NO_DEFERRALS if deferrals.empty?

        shim = ::Module.new
        deferrals.each_value do |(_definer, impl)|
          Axn::Internal::NativeMethods.define_own_instance_method(shim, impl.name) do |*args, **kwargs, &blk|
            impl.bind_call(self, *args, **kwargs, &blk)
          end
        end
        Axn::Internal::NativeMethods.include_module(base, shim)

        definers = deferrals.transform_values(&:first)
        KERNEL_IVAR_SET.bind_call(base, DEFERRALS_IVAR, { shim:, definers: })
        definers
      end

      # Which module axn stepped aside for, per name. The recorded answer rather than a fresh walk: once the
      # shim is installed it is itself the nearest declaration of the name, so a re-walk would report the shim.
      def self.definers(klass) = _state(klass)&.fetch(:definers) || NO_DEFERRALS

      def self.shim(klass) = _state(klass)&.fetch(:shim)

      def self._state(klass) = KERNEL_IVAR_GET.bind_call(klass, DEFERRALS_IVAR)
      private_class_method :_state

      # Captured as an UnboundMethod at include time, so a later reopening of the definer cannot silently
      # retarget a deferral the class already committed to.
      def self._collect(base)
        MethodShadowing.deferrable_names.each_with_object({}) do |name, acc|
          definer = MethodShadowing.inherited_definer(base, name)
          next if definer.nil?

          impl = Axn::Internal::NativeMethods.declared_instance_method(definer, name)
          acc[name] = [definer, impl] unless impl.nil?
        end
      end
      private_class_method :_collect
    end
  end
end
```

Note `impl.name` rather than the loop's `name`: an `UnboundMethod`'s own name is the one it answers to, and using it keeps the definition and the implementation from disagreeing if a definer aliased the method.

- [ ] **Step 5: Wire it into the include, and require it**

In `lib/axn/core.rb`, add beside the other requires (after `require "axn/core/method_shadowing"`):

```ruby
require "axn/core/instance_deferral"
```

In `lib/axn.rb`, inside `Axn.included`, after the `class_eval` block and before `Axn::Tools::Registry.register_class(base)`:

```ruby
    # Last, so the module it installs outranks every module the class_eval above included — including
    # `Axn.config.additional_includes`. A name the user's own hierarchy owns wins over axn's helper.
    Core::InstanceDeferral.install(base)
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb`
Expected: PASS.

- [ ] **Step 7: Full suite, then commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/instance_deferral.rb lib/axn/core.rb lib/axn.rb lib/axn/internal/native_methods.rb spec/axn/core/instance_deferral_spec.rb
git commit -m "PRO-3149: step aside for an instance method the user's hierarchy owns"
```

---

### Task 4: A declaration error names the real owner, not the shim

**Files:**
- Modify: `lib/axn/internal/name_ownership.rb`
- Test: `spec/axn/internal/name_ownership_spec.rb`, `spec/axn/core/instance_deferral_spec.rb`

**Interfaces:**
- Consumes: `Core::InstanceDeferral.definers(klass)`
- Produces: `NameOwnership.owner_of` maps a deferral shim back to the definer it stands for

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/instance_deferral_spec.rb`:

```ruby
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

    it "does not name axn's own source file" do
      action = Class.new(named_parent) { include Axn }

      expect { action.class_eval { expects :log } }.to raise_error(/(?!.*instance_deferral)/)
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
```

Append to `spec/axn/internal/name_ownership_spec.rb`:

```ruby
  describe ".owner_of with a deferral shim in the chain" do
    it "reports the module the shim stands for" do
      parent = Class.new { def log(*) = nil }
      action = Class.new(parent) { include Axn }

      expect(described_class.owner_of(action, :log)).to eq(parent)
    end

    it "reports the shim's own owner for a name it does not stand for" do
      parent = Class.new { def log(*) = nil }
      action = Class.new(parent) { include Axn }

      expect(described_class.owner_of(action, :info)).to eq(Axn::Core::Logging::InstanceMethods)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/internal/name_ownership_spec.rb -e "deferral shim" spec/axn/core/instance_deferral_spec.rb -e "collides with a deferred name"`
Expected: FAIL — `owner_of` returns the anonymous shim module, and the `expects :log` example either passes for the wrong reason (an anonymous owner label) or names axn's file.

- [ ] **Step 3: Resolve through the shim**

In `lib/axn/internal/name_ownership.rb`, replace `owner_of`:

```ruby
      def owner_of(klass, name)
        name = name.to_sym
        owner = Axn::Internal::NativeMethods.declared_instance_method(klass, name)&.owner
        return owner if owner.nil?

        # A deferral shim is axn's own bookkeeping, not an owner a message should ever name: it holds a wrapper
        # around some ancestor's method, so the honest answer to "whose name is this?" is that ancestor's. Left
        # unresolved, the anonymous module would send the author to axn's source for a collision with their own
        # base class.
        Axn::Core::InstanceDeferral.definers(klass)[name] || owner
      end
```

`Axn::Internal` naming a `Axn::Core` constant is the existing direction, not a new one: `Internal::ActionState` holds `Axn::Core::Contract::InstanceMethods.instance_method(:result)`. The reference resolves at call time, so no require cycle is introduced — `spec/axn/standalone_require_spec.rb` is the check that would catch it if one were.

The verdict was already correct before this change (an anonymous module is not in `SURRENDERABLE_OWNERS`, so the declaration was refused); what changes is that `describe`/`owner_label` now render the definer.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/internal/name_ownership_spec.rb spec/axn/core/instance_deferral_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, then commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/internal/name_ownership.rb spec/axn/internal/name_ownership_spec.rb spec/axn/core/instance_deferral_spec.rb
git commit -m "PRO-3149: name the base class a deferral stepped aside for"
```

---

### Task 5: Raise for the names axn cannot yield

**Files:**
- Modify: `lib/axn/exceptions.rb`, `lib/axn/core.rb` (`ClassMethods#call`), `lib/axn/core/instance_deferral.rb`
- Test: `spec/axn/core/instance_deferral_spec.rb`

**Interfaces:**
- Produces: `Axn::ContractViolation::UnsurrenderableInheritedMethod`; `Core::InstanceDeferral.assert_dispatchable_names_free!(klass)` (idempotent, memoized per class)

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/instance_deferral_spec.rb`:

```ruby
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

    it "propagates out of .call rather than settling into a result, since there is no action yet" do
      action = Class.new(service_base) { include Axn }

      expect { action.call }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod)
      expect { action.call! }.to raise_error(Axn::ContractViolation::UnsurrenderableInheritedMethod)
    end

    it "checks once per class" do
      action = Class.new(service_base) do
        include Axn
        def initialize(**) = super()
        def call = nil
      end
      allow(Axn::Core::MethodShadowing).to receive(:inherited_definer).and_call_original

      3.times { action.call }
      expect(Axn::Core::MethodShadowing).to have_received(:inherited_definer).at_most(3).times
    end

    it "leaves an ordinary action untouched" do
      action = Class.new do
        include Axn
        def call = nil
      end

      expect(action.call).to be_ok
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb -e "cannot yield"`
Expected: FAIL — the first example reports `ok? == true` (the silent-success bug this closes), and the constant does not exist.

- [ ] **Step 3: Add the exception**

In `lib/axn/exceptions.rb`, beside the other `ContractViolation` members:

```ruby
    # A name axn dispatches on the action itself — `call` from the executor, `_run` from `.call`, `initialize`
    # from `new` — that the class's own hierarchy also declares. Unlike the helpers, this one cannot be
    # surrendered: axn's definition must answer, so the inherited one would never run, and an action whose
    # inherited `call` never runs reports success for code that did not execute.
    class UnsurrenderableInheritedMethod < ContractViolation
      def initialize(klass:, name:, owner:)
        klass, name, owner = [klass, name, owner].map { |part| Axn::Internal::RenderedText.of(part) }
        super("#{owner} defines ##{name}, which #{klass} cannot inherit: axn must own that name to run the " \
              "action, so the inherited definition would never be called. Either define ##{name} on " \
              "#{klass} itself (axn's is then reachable with `super`), or compose #{owner} in rather than " \
              "inheriting from it.")
      end
    end
```

Check the file's existing rendering helper before writing this: `lib/axn/exceptions.rb` may only reach `Internal::Text.renderable` / `RenderedClassName` (reaching the reflection layer from here closes a require cycle that `spec/axn/standalone_require_spec.rb` catches). Use whichever of those the neighbouring classes use, with the same treatment for all three interpolated values.

- [ ] **Step 4: Add the assertion and call it from the funnel**

In `lib/axn/core/instance_deferral.rb`:

```ruby
      CHECKED_IVAR = :@__axn_dispatchable_names_checked

      # `call`, `_run` and `initialize` are dispatched on the action BY NAME from outside the module that defines
      # them, so axn cannot step aside for an inherited version the way it does for the helpers — and taking one
      # silently is worse than refusing it: an action whose inherited `call` is shadowed reports success for code
      # that never ran.
      #
      # Asked at execution rather than at include time because only the finished class answers it. A class may
      # legitimately define `call` itself AFTER `include Axn` — `Axn::Factory` builds exactly that shape — and
      # its own definition outranks both the inherited one and axn's default, so an include-time check would
      # refuse a legal build. `Core::ClassMethods#call` is the only funnel there is; nothing reaches `_run`
      # around it.
      def self.assert_dispatchable_names_free!(klass)
        return if KERNEL_IVAR_GET.bind_call(klass, CHECKED_IVAR)

        Axn::Internal::NameOwnership::UNSURRENDERABLE.each do |name|
          owner = MethodShadowing.inherited_definer(klass, name)
          next if owner.nil?

          raise Axn::ContractViolation::UnsurrenderableInheritedMethod.new(klass:, name:, owner:)
        end

        KERNEL_IVAR_SET.bind_call(klass, CHECKED_IVAR, true)
      end
```

In `lib/axn/core.rb`, `ClassMethods#call`:

```ruby
      def call(**)
        Core::InstanceDeferral.assert_dispatchable_names_free!(self)
        Axn::Internal::ActionState.result(new(**).tap(&:_run))
      end
```

`call!` routes through `call`, so it needs no change.

Two details the tests above pin down. The guard asks TWO questions, not one: does a non-axn ancestor declare the name, AND does the effective dispatch land on an axn-core-owned method? `inherited_definer` alone is not enough — it excludes the class itself, so a class-body `def call` (the factory's included) is invisible to it and the parent would still be found. Only "an ancestor declares it AND axn's own definition is what answers" is a refusal. And the memo flag is a class-level ivar, which subclasses do not inherit — a subclass of an action re-checks itself, which is correct, since it may have introduced its own `def call`.

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb`
Expected: PASS.

- [ ] **Step 6: Full suite, then commit**

Watch for existing specs that build an action under a superclass owning `call`/`initialize`; any that break are reporting the bug this task closes, so fix the fixture rather than the guard.

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/exceptions.rb lib/axn/core.rb lib/axn/core/instance_deferral.rb spec/axn/core/instance_deferral_spec.rb
git commit -m "PRO-3149: refuse an inherited call/initialize instead of swallowing it"
```

---

### Task 6: Warn once per definer

**Files:**
- Modify: `lib/axn/core/instance_deferral.rb`
- Test: `spec/axn/core/instance_deferral_spec.rb`

**Interfaces:**
- Produces: `InstanceDeferral.install` emits one `Axn.config.logger.warn` per `(definer, name)` per process

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/instance_deferral_spec.rb`:

```ruby
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

    it "names the class, the owner, the name, and both ways to resolve it" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      stub_const("ChargeCard", Class.new(ApplicationService) { include Axn })

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

    it "does not re-announce a deferral after configuration is reset" do
      stub_const("ApplicationService", Class.new { def log(*) = nil })
      Class.new(ApplicationService) { include Axn }
      expect(warnings.size).to eq(1)

      Axn.reset_config!
      logger = instance_double(Logger, info: nil, debug: nil)
      allow(logger).to receive(:warn) { |msg| warnings << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)
      Class.new(ApplicationService) { include Axn }

      expect(warnings.size).to eq(1)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb -e "the warning"`
Expected: FAIL — no `warn` is emitted and `_reset_warned_for_specs!` does not exist.

- [ ] **Step 3: Implement**

In `lib/axn/core/instance_deferral.rb`, add to `install` after the ivar is set:

```ruby
        deferrals.each { |name, (definer, _impl)| _warn_once(base, name, definer) }
```

and:

```ruby
      # Keyed to the DEFINER's method rather than to the class that inherited it: one `ApplicationService#log`
      # under fifty actions is one line at boot, not fifty. A definer that lies about `hash`/`eql?` gets warned
      # about more than once, which is the right way for a courtesy to degrade.
      #
      # Never cleared. This is the record of a side effect already committed — the process has announced the
      # deferral — so a configuration reset in a test suite must not make it announce it again.
      WARNED = {}
      private_constant :WARNED

      def self._warn_once(base, name, definer)
        return unless WARNED[[definer, name]].nil?

        WARNED[[definer, name]] = true
        owner = Axn::Internal::Rendering.module_name(definer)
        klass = Axn::Internal::Rendering.module_name(base)
        Axn.config.logger.warn(
          "[#{klass}] axn did not define ##{name}: #{owner} already defines it, so calls reach #{owner}'s " \
          "version. Declare `prefer_inherited :#{name}` to confirm that, or `prefer_axn :#{name}` to use " \
          "axn's instead."
        )
      end
      private_class_method :_warn_once

      # Specs assert the once-per-definer property, which needs the record cleared between examples. Deliberately
      # not part of any public reset: see WARNED.
      def self._reset_warned_for_specs! = WARNED.clear
      private_class_method :_reset_warned_for_specs!
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, then commit**

Other spec files that build a shadowing fixture will now log a warning; if that breaks an expectation of quiet logging, clear the record in that spec rather than suppressing the warning.

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/instance_deferral.rb spec/axn/core/instance_deferral_spec.rb
git commit -m "PRO-3149: announce a deferral once per definer"
```

---

### Task 7: `prefer_inherited` / `prefer_axn`

**Files:**
- Modify: `lib/axn/core/instance_deferral.rb`, `lib/axn/core.rb` (include the new `ClassMethods`)
- Test: `spec/axn/core/instance_deferral_spec.rb`

**Interfaces:**
- Produces: `prefer_inherited(*names)` and `prefer_axn(*names)` on every action class

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/instance_deferral_spec.rb`:

```ruby
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

    it "restores the canonical owner, so a declaration may surrender the name again" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :fail!
      end

      expect(Axn::Internal::NameOwnership.owner_of(action, :fail!)).to eq(Axn::Core)
      expect(described_class.definers(action)).not_to have_key(:fail!)
    end

    it "leaves the other deferrals on the class intact" do
      action = Class.new(parent) do
        include Axn
        prefer_axn :fail!
      end

      expect(action.send(:new).log).to eq("PARENT-LOG")
    end

    it "is a satisfied assertion when nothing was deferred" do
      expect { Class.new { include Axn; prefer_axn :log } }.not_to raise_error
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
      end

      expect(action.send(:new).log).to eq("PARENT-LOG")
      expect(warnings).to be_empty
    end

    it "raises when nothing in the hierarchy owns the name" do
      expect { Class.new { include Axn; prefer_inherited :log } }.to raise_error(
        Axn::ContractViolation, /nothing.*inherit|no inherited/i
      )
    end
  end

  describe "the guard on both declarations" do
    %i[call _run initialize].each do |name|
      it "refuses #{name}, which axn dispatches to run the action" do
        expect { Class.new { include Axn; prefer_inherited name } }
          .to raise_error(Axn::ContractViolation, /axn itself/)
        expect { Class.new { include Axn; prefer_axn name } }
          .to raise_error(Axn::ContractViolation, /axn itself/)
      end
    end

    it "refuses ambient_context, a sentinel rather than a convenience" do
      expect { Class.new { include Axn; prefer_axn :ambient_context } }
        .to raise_error(Axn::ContractViolation, /AmbientContext/)
    end

    it "refuses a Ruby-owned name" do
      expect { Class.new { include Axn; prefer_axn :inspect } }
        .to raise_error(Axn::ContractViolation, /Kernel|Object/)
    end

    it "refuses an axn internal" do
      expect { Class.new { include Axn; prefer_axn :_forward_to_class } }
        .to raise_error(Axn::ContractViolation, /internals/)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb -e prefer_`
Expected: FAIL — `undefined method 'prefer_axn'`.

- [ ] **Step 3: Implement the declarations**

In `lib/axn/core/instance_deferral.rb`:

```ruby
      module ClassMethods
        # Say which implementation is live, for a name this class's own hierarchy and axn both define. Neither
        # changes what axn permits — a class-body `def` already surrenders any of these names — they make the
        # choice visible where the reader of the class body will look for it.
        #
        # Each raises when the outcome it names cannot be delivered: `prefer_inherited` when nothing above the
        # class declares the name, `prefer_axn` never (axn's is live already when there was no deferral).
        def prefer_inherited(*names)
          names.each do |name|
            name = InstanceDeferral.send(:_assert_deferrable!, self, name)
            next unless InstanceDeferral.definers(self)[name].nil?

            raise Axn::ContractViolation, "`prefer_inherited :#{name}` has nothing to prefer: no ancestor of " \
                                          "this class before Object defines ##{name}, so axn's is the only " \
                                          "implementation. Remove the declaration, or check the name."
          end
        end

        def prefer_axn(*names)
          names.each do |name|
            name = InstanceDeferral.send(:_assert_deferrable!, self, name)
            InstanceDeferral.send(:_reclaim, self, name)
          end
        end
      end
```

and, alongside the other module functions:

```ruby
      # The same question a declaration asks, so the two cannot drift: a name axn would define and may hand
      # over. Anything else — `call`, an axn internal, a sentinel, Ruby's own — is refused with the message
      # NameOwnership already writes for it.
      def self._assert_deferrable!(klass, name)
        name = name.to_sym
        return name if MethodShadowing.deferrable_names.include?(name)

        conflict = Axn::Internal::NameOwnership.conflict_for(klass, name) || :unsurrenderable
        raise Axn::ContractViolation,
              "##{name} is not a name axn will hand to your class: it belongs to " \
              "#{Axn::Internal::NameOwnership.describe(conflict, name:)}. Only axn's own helpers can be " \
              "preferred either way."
      end
      private_class_method :_assert_deferrable!

      # Removing the wrapper from the shim restores the canonical owner outright, which is what makes the
      # declaration honest: `NameOwnership` then reports `Axn::Core` again, and a field declaration may
      # surrender the name as usual. Per-name, so the class's other deferrals stand.
      def self._reclaim(klass, name)
        state = _state(klass)
        return if state.nil? || state[:definers][name].nil?

        Axn::Internal::NativeMethods.remove_own_instance_method(state[:shim], name)
        state[:definers].delete(name)
      end
      private_class_method :_reclaim
```

In `lib/axn/core.rb`'s `included` block, beside the other DSL includes:

```ruby
        extend Core::InstanceDeferral::ClassMethods
```

`_assert_deferrable!` is reached through `send` from `ClassMethods` because it is axn-internal and must not become a public class method on every action; if that reads badly to the implementer, promote the two helpers to a `module_function`-free public API on `InstanceDeferral` and mark them with the `_` convention instead — do not make them public DSL.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/core/instance_deferral_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, then commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/instance_deferral.rb lib/axn/core.rb spec/axn/core/instance_deferral_spec.rb
git commit -m "PRO-3149: let a class say which implementation is live"
```

---

### Task 8: Behavioural matrix across the whole surface

**Files:**
- Modify: `spec/axn/core/method_shadowing_integrity_spec.rb`

**Interfaces:**
- Consumes: everything above. Adds no production code.

- [ ] **Step 1: Write the matrix**

Append to `spec/axn/core/method_shadowing_integrity_spec.rb`. The existing file shadows each sugar name with a class-body `def`; this adds the inherited shape of the same grid, driven off the derived surface so a new helper is covered without editing the spec.

```ruby
  describe "an inherited definition of each surrenderable name" do
    Axn::Core::MethodShadowing.deferrable_names.each do |name|
      context "##{name}" do
        let(:parent) do
          Class.new do
            define_method(name) { |*| :parent_implementation }
          end
        end

        it "wins over axn's helper" do
          action = Class.new(parent) { include Axn }
          expect(action.send(:new).public_send(name)).to eq(:parent_implementation)
        end

        it "leaves every other axn path working" do
          action = Class.new(parent) do
            include Axn
            expects :input
            exposes :output
            def call = expose(output: input * 2)
          end

          result = action.call(input: 21)
          expect(result).to be_ok
          expect(result.output).to eq(42)
        end

        it "is reachable through super from a class-body wrapper" do
          action = Class.new(parent) do
            include Axn
            define_method(name) { |*args| [:wrapped, super(*args)] }
          end

          expect(action.send(:new).public_send(name)).to eq([:wrapped, :parent_implementation])
        end
      end
    end
  end

  describe "a name only Ruby owns" do
    %i[warn inspect hash then tap].each do |name|
      it "leaves ##{name} to axn or to Ruby, never deferred" do
        action = Class.new { include Axn }
        expect(Axn::Core::InstanceDeferral.definers(action)).not_to have_key(name)
      end
    end

    it "keeps warn on axn's logger rather than Kernel's" do
      messages = []
      logger = instance_double(Logger, info: nil, debug: nil)
      allow(logger).to receive(:warn) { |msg| messages << msg }
      allow(Axn.config).to receive(:logger).and_return(logger)

      action = Class.new do
        include Axn
        def call = warn("to the logger")
      end

      expect { action.call }.not_to output.to_stderr
      expect(messages.join).to include("to the logger")
    end
  end

  describe "no internal error reaches a side channel" do
    it "reports nothing to on_ignored_exception while a deferral is in place" do
      ignored = []
      Axn.config.on_ignored_exception = ->(e, **) { ignored << e }
      parent = Class.new { def log(*) = :parent }

      action = Class.new(parent) do
        include Axn
        exposes :out
        def call = expose(out: :ok)
      end

      expect(action.call).to be_ok
      expect(ignored).to be_empty
    ensure
      Axn.config.on_ignored_exception = nil
    end
  end
```

Check `spec/axn/core/exception_report_facets_spec.rb` or the PRO-3139 specs for the exact `on_ignored_exception` assignment idiom before writing that last example, and match it.

- [ ] **Step 2: Run the matrix**

Run: `bundle exec rspec spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: PASS. A failure here is a real gap — do not weaken an example to make it pass.

- [ ] **Step 3: Full suite plus the Rails path, then commit**

```bash
bundle exec rspec && bundle exec rubocop
cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec; cd -
git add spec/axn/core/method_shadowing_integrity_spec.rb
git commit -m "PRO-3149: cover the inherited half of the shadowing matrix"
```

---

### Task 9: Documentation

**Files:**
- Create: `docs/advanced/inheritance.md`
- Modify: `docs/.vitepress/config.mjs`, `AGENTS.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: the behaviour built above. No production code.

- [ ] **Step 1: Write the Advanced page**

Create `docs/advanced/inheritance.md`. Scope it to the author who includes Axn into a class that already has a hierarchy — this must NOT appear in the intro or usage flow, where `class Foo; include Axn` makes none of it observable. Cover, in this order:

1. The rule: a method your own hierarchy declares wins over axn's helper of the same name; a method Ruby declares (`warn`, `inspect`, `hash`) does not, so axn keeps those.
2. Which names it applies to — list the 17 grouped as the spec groups them, prose-framed as "axn's convenience helpers" rather than as an API contract.
3. A worked `ApplicationService#log` example showing the deferral, the warning, and `prefer_inherited :log` to confirm it. The warning fires the FIRST TIME the action runs, not at `include Axn` — a line already written to the log cannot be unsaid by a declaration later in the same class body, so silencing is only possible once the class body has finished. Say so plainly; an author who never calls an action never sees its warning.
4. `prefer_axn :fail!`, with the reason it exists: `super` from your class body reaches the inherited version, so this is the only route back to axn's. Add the one consequence a reader would otherwise discover by accident: a class-body `def` of the same name still wins over `prefer_axn`, which turns the declaration into a redirect for that method's `super` rather than a no-op.
5. The refusal: an inherited `call` or `initialize` raises at first `.call`, because axn dispatches those names to run the action and an inherited one would never execute. Show the error and both fixes (define it on the action, or compose instead of inherit).
6. A short closing section on the class-method side (`description`, `input_schema`, `output_schema` — PRO-2875), which is undocumented on the site today: same principle, one receiver over.

Follow the docs conventions in `AGENTS.md` (one line per Markdown paragraph; `[!code focus]` only in full-scaffold blocks).

- [ ] **Step 2: Register it in the sidebar**

In `docs/.vitepress/config.mjs`, in the `Advanced` items array, after `Conventions`:

```js
          { text: 'Inheritance & Method Conflicts', link: '/advanced/inheritance' },
```

- [ ] **Step 3: Write the AGENTS.md rule**

Add one entry to `AGENTS.md`, in the same bullet list that carries "Internals never dispatch a name a user can take" and "Reserved names are derived from ownership, never listed". It must state both halves of the walk in one place, since the acceptance criterion is that a reader meets one rule rather than two similar checks:

- `Axn::Core::MethodShadowing` decides whether axn may define a name, for both receivers, through one ancestry walk (`_external_definer`).
- Class side: `base.singleton_class`'s ancestors, untruncated, `base` included.
- Instance side: `base`'s ancestors, truncated at `::Object`, `base` and its prepends excluded — `Kernel` owns `warn`/`inspect`/`hash`/`then`/`tap` and sits behind `::Object`, so truncating there is what keeps them axn's; an untruncated walk would silently redirect `warn("msg")` inside every action to stderr.
- Both skip `Axn::Core::*` owners only, so a satellite adapter's module counts as external.
- The deferrable surface is `SURRENDERABLE_OWNERS`' public methods minus `internal_name?`; `UNSURRENDERABLE` names raise at the execution funnel instead, because only the finished class reveals whether the class defines its own. That refusal is TWO questions — a non-axn ancestor declares the name AND axn's own definition is what a dispatch reaches — so a class defining the name itself is never refused.
- A declaration (`prefer_inherited`/`prefer_axn`) only ever adds a wrapper to the DECLARING class's own module; it never edits an inherited one, which is what stops a subclass changing its parent's and siblings' behaviour.
- New user-facing sugar therefore needs no edit here; adding a whole new sugar module does.

- [ ] **Step 4: CHANGELOG**

Add entries under the unreleased version heading. Confirm which heading that is first — a bumped-but-uncut version heading IS the unreleased section; verify with `git tag --list | tail -5` and the published versions on rubygems rather than assuming the top heading is released. Two entries:

- `[BUGFIX]` an instance method the including class's own hierarchy owns is no longer silently shadowed by axn's helper of the same name; `prefer_inherited` / `prefer_axn` name which one is live.
- `[BREAKING]` an inherited `call` or `initialize` now raises `Axn::ContractViolation::UnsurrenderableInheritedMethod` at first `.call`, where it previously reported success without running the inherited method. This reaches `Axn::Factory.build(superclass:)` too — a factory axn built over a superclass that defines `initialize` now raises where it previously ran with the parent's initializer skipped.

Write what changed and what a consumer must do, not how it was built.

- [ ] **Step 5: Build the docs and commit**

```bash
yarn docs:check   # vitepress build + link check
bundle exec rspec && bundle exec rubocop
git add docs AGENTS.md CHANGELOG.md
git commit -m "PRO-3149: document both sides of the shadowing rule"
```

---

## Self-review notes for the executor

- **Spec coverage.** §1 → Task 1; §2 → Task 2; §3 → Tasks 3 and 5; §4 → Task 3; §5 → Task 7; §6 → Task 6; §7 → Task 4; §8 → Task 9; §9 → Task 9; Testing → Tasks 1–8; Out of scope → nothing to do.
- **The one uncertainty left in the plan** is the rendering helper `Axn::ContractViolation::UnsurrenderableInheritedMethod` may use (Task 5, Step 3): `lib/axn/exceptions.rb` deliberately reaches only `Internal::Text.renderable` / `RenderedClassName`, and `spec/axn/standalone_require_spec.rb` fails if that widens. Read the neighbouring exception classes and match them rather than importing `Internal::Rendering` there.
- **Do not add a name array anywhere.** If a task seems to need one, the derivation is wrong; stop and say so.
