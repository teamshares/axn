# frozen_string_literal: true

# Which adapter, with whose config, a `call_async` enqueues through, over every adapter style and inheritance shape.
# The invariant: the enqueue runs the hook THIS class's own declaration installs, with this class's config. A class
# keeps every adapter module it or an ancestor ever included, and re-including one is a no-op, so plain method
# lookup is not enough on its own.
RSpec.describe "call_async adapter dispatch grid" do
  let(:log) { [] }

  before do
    Sidekiq::Testing.fake!
    Sidekiq::Queues.clear_all
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  after { Axn::Async::Adapters.clear! }

  # A stand-in for the enqueue-all orchestrator, which the config setters configure by constant. Standalone
  # rather than a subclass of the real one: other files configure the real orchestrator, and what its own
  # declarations recorded would serve a subclass's declarations, making these rows depend on file order.
  def stub_orchestrator
    stub_const("Axn::Async::EnqueueAllOrchestrator", build_axn { expects :target_class_name, :static_args, allow_blank: true })
  end

  def action(const_name, parent = nil, &body)
    klass = parent ? Class.new(parent) : build_axn { expects :name }
    klass.class_eval(&body) if body
    stub_const(const_name, klass)
  end

  # What the call enqueued: ["active_job", queue], ["sidekiq", queue], a custom hook's own log entry, or ["raised"].
  def outcome
    log.clear
    Sidekiq::Queues.clear_all
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    yield
    active_job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    return ["active_job", active_job[:queue]] if active_job

    sidekiq_queues = Sidekiq::Queues.jobs_by_queue.select { |_queue, jobs| jobs.any? }.keys
    return ["sidekiq", *sidekiq_queues] if sidekiq_queues.any?

    log.last || ["nothing"]
  rescue NotImplementedError
    ["raised"]
  end

  # A registered custom adapter, in one of the styles an adapter can supply its class-side hook:
  # - a Concern whose ClassMethods defines the hook, includes it, or prepends it (the hook reads the class's
  #   `_async_config` when it runs);
  # - a plain module whose own `included` hook extends the class with a fixed hook module, or with a module it
  #   builds per class from that class's `_async_config`;
  # - a Concern with a ClassMethods hook whose `included` block also extends a per-class module built from config,
  #   which sits above ClassMethods and so is what the class dispatches;
  # - a plain module whose `included` hook defines the hook straight onto the class's singleton.
  # Ruby runs a plain module's `included` on every `include`, even one that adds nothing; a Concern's `included`
  # block runs only when the module is actually added.
  def register_custom(style)
    log = self.log
    reads_config = proc { |_kwargs| log << ["custom", _async_config[:tag]] }
    hook = Module.new { private define_method(:_enqueue_async_job, &reads_config) }
    built = ->(base) { built_hook_module(base._async_config[:tag]) }

    adapter =
      case style
      when :class_methods_direct then concern_adapter(Module.new { private define_method(:_enqueue_async_job, &reads_config) })
      when :class_methods_include then concern_adapter(Module.new.tap { |m| m.include(hook) })
      when :class_methods_prepend then concern_adapter(Module.new.tap { |m| m.prepend(hook) })
      when :extends_fixed_module then plain_adapter { |base| base.extend(hook) }
      when :extends_module_built_from_config then plain_adapter { |base| base.extend(built.call(base)) }
      when :concern_with_built_override
        class_methods = Module.new { private define_method(:_enqueue_async_job) { |_kwargs| log << ["class_methods", _async_config[:tag]] } }
        concern_adapter(class_methods) { extend(built.call(self)) }
      when :defines_singleton_method
        plain_adapter do |base|
          tag = base._async_config[:tag]
          base.define_singleton_method(:_enqueue_async_job) { |_kwargs| log << ["custom", tag] }
          base.singleton_class.send(:private, :_enqueue_async_job)
        end
      end
    Axn::Async::Adapters.register(:custom, adapter)
  end

  def built_hook_module(tag)
    log = self.log
    Module.new { private define_method(:_enqueue_async_job) { |_kwargs| log << ["custom", tag] } }
  end

  def concern_adapter(class_methods, &included_block)
    mod = Module.new { extend ActiveSupport::Concern }
    mod.const_set(:ClassMethods, class_methods)
    mod.included(&included_block) if included_block
    mod
  end

  def plain_adapter(&on_included)
    Module.new.tap { |m| m.define_singleton_method(:included, &on_included) }
  end

  custom_styles = %i[class_methods_direct class_methods_include class_methods_prepend extends_fixed_module
                     extends_module_built_from_config concern_with_built_override defines_singleton_method]

  custom_styles.each do |style|
    context "with a custom adapter (#{style})" do
      before { register_custom(style) }

      # A Concern's `included` block runs only when the module is actually added, so a class that re-declares an
      # adapter its ancestry (or it itself) already added never gets a module built from its OWN config. No
      # dispatcher can reach a hook that was never built: these cells enqueue through the right adapter with the
      # config of the declaration that did build one. Meeting them needs an adapter contract that is handed the
      # declaring class (for example a per-declaration hook on the adapter module), which is a separate decision.
      # The inert-declaration guard cannot refuse them either: at declaration they look exactly like a valid
      # Concern re-declared with new config (an ancestor's recorded hook serves it), and only running the hook
      # tells a config baked in at inclusion from one read at call time.
      def unreachable_without_adapter_contract_change!(style)
        pending "a Concern adapter builds its class-side module only on first inclusion" if style == :concern_with_built_override
      end

      it "single-level declaration" do
        a = action("GridA") { async :custom, tag: "a" }
        expect(outcome { a.call_async(name: "x") }).to eq(%w[custom a])
      end

      it "single-level declaration after an unrelated class declared the same adapter" do
        action("GridA") { async :custom, tag: "a" }
        b = action("GridB") { async :custom, tag: "b" }
        expect(outcome { b.call_async(name: "x") }).to eq(%w[custom b])
      end

      it "child re-declaring the parent's adapter, same config" do
        parent = action("GridParent") { async :custom, tag: "p" }
        child = action("GridChild", parent) { async :custom, tag: "p" }
        expect(outcome { child.call_async(name: "x") }).to eq(%w[custom p])
      end

      it "child re-declaring the parent's adapter, different config" do
        unreachable_without_adapter_contract_change!(style)
        parent = action("GridParent") { async :custom, tag: "p" }
        child = action("GridChild", parent) { async :custom, tag: "c" }
        expect(outcome { child.call_async(name: "x") }).to eq(%w[custom c])
      end

      it "custom -> active_job -> custom, same config" do
        parent = action("GridParent") { async :custom, tag: "p" }
        child = action("GridChild", parent) { async(:active_job) {} }
        grandchild = action("GridGrandchild", child) { async :custom, tag: "p" }
        expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[custom p])
      end

      it "custom -> active_job -> custom, different config" do
        unreachable_without_adapter_contract_change!(style)
        parent = action("GridParent") { async :custom, tag: "p" }
        child = action("GridChild", parent) { async(:active_job) {} }
        grandchild = action("GridGrandchild", child) { async :custom, tag: "g" }
        expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[custom g])
      end

      it "custom under an `async false` parent" do
        parent = action("GridParent") { async false }
        child = action("GridChild", parent) { async :custom, tag: "c" }
        expect(outcome { child.call_async(name: "x") }).to eq(%w[custom c])
      end

      it "inheriting the default" do
        allow(Axn.config).to receive(:_apply_async_to_enqueue_all_orchestrator)
        Axn.config.set_default_async(:custom, tag: "d")
        a = action("GridA")
        expect(outcome { a.call_async(name: "x") }).to eq(%w[custom d])
      ensure
        Axn.config.set_default_async(false)
      end

      it "returning to the default under an :active_job parent" do
        allow(Axn.config).to receive(:_apply_async_to_enqueue_all_orchestrator)
        Axn.config.set_default_async(:custom, tag: "d")
        a = action("GridA")
        a.call_async(name: "x")
        b = action("GridB", a) { async(:active_job) {} }
        c = action("GridC", b) { async }
        expect(outcome { c.call_async(name: "x") }).to eq(%w[custom d])
      ensure
        Axn.config.set_default_async(false)
      end

      it "enqueue-all orchestrator switched to the custom adapter, away, and back with new config" do
        unreachable_without_adapter_contract_change!(style)
        stub_orchestrator
        Axn.config.set_enqueue_all_async(:custom, tag: "o1")
        if style == :defines_singleton_method
          # A hook defined directly on the orchestrator shadows any module Active Job adds, so that switch is refused.
          expect { Axn.config.set_enqueue_all_async(:active_job) {} }
            .to raise_error(ArgumentError, /`_enqueue_async_job` is defined directly on Axn::Async::EnqueueAllOrchestrator \(by the :custom adapter\)/)
          next
        end
        Axn.config.set_enqueue_all_async(:active_job) {}
        Axn.config.set_enqueue_all_async(:custom, tag: "o2")
        orchestrator = Axn::Async::EnqueueAllOrchestrator
        expect(outcome { orchestrator.call_async(target_class_name: "Anything", static_args: {}) }).to eq(%w[custom o2])
      ensure
        Axn.config.set_enqueue_all_async(nil)
      end
    end
  end

  # Custom adapters whose class-side methods collide with another adapter's. A re-declaration that cannot take
  # effect is refused at declaration; a helper name two adapters on one class both define is warned about.
  context "with guardrails for colliding custom adapters" do
    let(:warnings) { [] }

    before do
      allow(Axn.config.logger).to receive(:warn).and_wrap_original do |original, *args, &message|
        warnings << (message ? message.call : args.first)
        original.call(*args, &message)
      end
    end

    def register_adapter(key, &included_hook)
      Axn::Async::Adapters.register(key, plain_adapter(&included_hook))
    end

    def concern_with(class_methods) = concern_adapter(class_methods)

    it "refuses switching a class whose hook is defined directly on it to another adapter" do
      register_custom(:defines_singleton_method)
      report = action("GridReport") { async :custom, tag: "r" }

      expect { report.async :sidekiq, queue: "s" }.to raise_error(
        ArgumentError,
        "`async :sidekiq` on GridReport can't take effect — `_enqueue_async_job` is defined directly on GridReport " \
        "(by the :custom adapter) and shadows it. Define the adapter's class-side methods in a module " \
        "(e.g. a ClassMethods concern) so a later declaration can replace them.",
      )
      expect(report._async_adapter).to eq(:custom)
      expect(outcome { report.call_async(name: "x") }).to eq(%w[custom r])
    end

    # An adapter module already present before the first `async` (included by hand, or through an ancestor that
    # never declared it) records no hook, but the hook the class reaches is still that adapter's own.
    {
      "included by hand into the class" => ->(adapter) { action("GridReport") { include adapter } },
      "inherited from an ancestor that included it by hand" => ->(adapter) { action("GridReport", action("GridBase") { include adapter }) },
    }.each do |label, build|
      %i[class_methods_direct extends_fixed_module].product(%w[a b]).each do |style, second_tag|
        it "allows re-declaring a custom adapter (#{style}) #{label} (#{second_tag == 'a' ? 'same' : 'new'} config)" do
          register_custom(style)
          report = instance_exec(Axn::Async::Adapters.find(:custom), &build)
          report.async :custom, tag: "a"
          report.async :custom, tag: second_tag
          expect(outcome { report.call_async(name: "x") }).to eq(["custom", second_tag])
        end
      end
    end

    it "allows switching to an adapter whose own ClassMethods reaches a hook module another adapter also added" do
      log = self.log
      shared = stub_const("GridSharedHook", Module.new { private define_method(:_enqueue_async_job) { |_kwargs| log << ["shared", _async_config[:tag]] } })
      register_adapter(:first) { |base| base.extend(shared) }
      Axn::Async::Adapters.register(:second, concern_with(Module.new.tap { |m| m.include(shared) }))
      report = action("GridReport") { async :first, tag: "f" }
      report.async :second, tag: "s"
      expect(outcome { report.call_async(name: "x") }).to eq(%w[shared s])
    end

    it "lets a subclass of such a class declare another adapter, which does take effect there" do
      register_custom(:defines_singleton_method)
      parent = action("GridParent") { async :custom, tag: "p" }
      child = action("GridChild", parent) { async :sidekiq, queue: "c" }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[sidekiq c])
    end

    # Both adapters here extend the same module, so it is arguably :second's hook too. Nothing :second's inclusion
    # changed shows that (its extend is a no-op), and it has no ClassMethods to read, so the module reads as :first's
    # alone and the switch is refused. An adapter whose ClassMethods reaches the shared module is allowed (above).
    it "refuses switching to an adapter whose hook is a module another adapter already added" do
      log = self.log
      shared = stub_const("GridSharedHook", Module.new { private define_method(:_enqueue_async_job) { |_kwargs| log << ["shared"] } })
      register_adapter(:first) { |base| base.extend(shared) }
      register_adapter(:second) { |base| base.extend(shared) }
      report = action("GridReport") { async :first }

      expect { report.async :second }.to raise_error(
        ArgumentError,
        "`async :second` on GridReport can't take effect — GridReport already reaches `_enqueue_async_job` through " \
        "GridSharedHook (by the :first adapter), and the :second adapter adds nothing that replaces it. Give each " \
        "adapter its own class-side module that defines its hook, so a later declaration can replace it.",
      )
    end

    it "warns when a newly declared adapter defines a helper another adapter on the class already defines" do
      log = self.log
      first = Module.new do
        define_method(:_enqueue_async_job) { |_kwargs| log << ["first", build_payload] }
        define_method(:build_payload) { "first" }
        private :_enqueue_async_job, :build_payload
      end
      second = Module.new do
        define_method(:_enqueue_async_job) { |_kwargs| log << ["second", build_payload] }
        define_method(:build_payload) { "second" }
        private :_enqueue_async_job, :build_payload
      end
      Axn::Async::Adapters.register(:first, concern_with(first))
      Axn::Async::Adapters.register(:second, concern_with(second))
      parent = action("GridParent") { async :first }
      # Named before declaring, as a `class GridChild < GridParent` body is.
      child = stub_const("GridChild", Class.new(parent))
      child.async :second

      expect(warnings).to eq([
                               "[Axn] GridChild: the :second and :first async adapters both define `build_payload` as class-side methods, " \
                               "so the one included later answers for both. Prefix each adapter's helper names so they cannot collide.",
                             ])
    end

    # An adapter adds class-side helpers either as modules in the singleton ancestry or straight into the singleton
    # class's own table (`define_singleton_method` in its `included` hook). Both kinds are compared, both ways.
    def helper_adapter(key, helper_via:)
      log = self.log
      class_methods = Module.new { private define_method(:_enqueue_async_job) { |_kwargs| log << [key.to_s] } }
      class_methods.define_method(:build_payload) { key.to_s } if helper_via == :module
      adapter = concern_with(class_methods)
      adapter.included { define_singleton_method(:build_payload) { key.to_s } } if helper_via == :singleton
      Axn::Async::Adapters.register(key, adapter)
    end

    def collision_warning(declared, other)
      "[Axn] GridReport: the #{declared.inspect} and #{other.inspect} async adapters both define `build_payload` as " \
        "class-side methods, so the one included later answers for both. Prefix each adapter's helper names so they cannot collide."
    end

    {
      "singleton vs singleton" => %i[singleton singleton],
      "singleton vs module" => %i[module singleton],
      "module vs singleton" => %i[singleton module],
    }.each do |label, (first_via, second_via)|
      it "warns on a helper collision, #{label} (the later adapter's helper vs the earlier one's)" do
        helper_adapter(:first, helper_via: first_via)
        helper_adapter(:second, helper_via: second_via)
        report = stub_const("GridReport", build_axn { expects :name })
        report.async :first
        report.async :second
        report.async :first

        expect(warnings).to eq([collision_warning(:second, :first)])
        expect(outcome { report.call_async(name: "x") }).to eq(["first"])
      end
    end

    it "does not count a class method the class defines itself as an adapter helper" do
      helper_adapter(:second, helper_via: :module)
      Axn::Async::Adapters.register(:first, concern_with(Module.new { private define_method(:_enqueue_async_job) { |_kwargs| nil } }))
      report = stub_const("GridReport", build_axn { expects :name })
      report.define_singleton_method(:build_payload) { "own" }
      report.async :first
      report.async :second

      expect(warnings).to be_empty
    end

    it "neither refuses nor warns for any built-in re-declaration" do
      a = action("GridA") { async :sidekiq, queue: "a" }
      a.async(:active_job) { queue_as "b" }
      a.async :sidekiq, queue: "c"
      a.async :sidekiq, queue: "c"
      a.async false
      a.async(:active_job) { queue_as "d" }
      child = action("GridChild", a) { async :sidekiq, queue: "e" }
      grandchild = action("GridGrandchild", child) { async(:active_job) { queue_as "f" } }

      expect(warnings).to be_empty
      expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[active_job f])
    end

    it "allows re-declaring a custom adapter with identical config, and with new config" do
      register_custom(:defines_singleton_method)
      a = action("GridA") { async :custom, tag: "a" }
      a.async :custom, tag: "a"
      a.async :custom, tag: "b"
      expect(outcome { a.call_async(name: "x") }).to eq(%w[custom b])
    end
  end

  # A built-in adapter's per-declaration artefacts (the Active Job proxy, the Sidekiq worker subclass) are built from
  # the declaration's config. Each declaration must get its own, including a class re-declaring an adapter it used
  # before and a subclass re-declaring one its parent has already enqueued through.
  context "with a built-in adapter re-declared after it has enqueued" do
    it "active_job, same class returning to it with a new block" do
      a = action("GridA") { async(:active_job) { queue_as "a" } }
      a.call_async(name: "x")
      a.async :sidekiq, queue: "s"
      a.async(:active_job) { queue_as "b" }
      expect(outcome { a.call_async(name: "x") }).to eq(%w[active_job b])
    end

    it "active_job, same class re-declared with a new block" do
      a = action("GridA") { async(:active_job) { queue_as "a" } }
      a.call_async(name: "x")
      a.async(:active_job) { queue_as "b" }
      expect(outcome { a.call_async(name: "x") }).to eq(%w[active_job b])
    end

    it "active_job, subclass re-declaring with a new block after the parent enqueued" do
      parent = action("GridParent") { async(:active_job) { queue_as "p" } }
      parent.call_async(name: "x")
      child = action("GridChild", parent) { async(:active_job) { queue_as "c" } }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[active_job c])
      expect(outcome { parent.call_async(name: "x") }).to eq(%w[active_job p])
    end

    it "active_job, a subclass re-declaring it with keyword config is refused like a first declaration" do
      parent = action("GridParent") { async(:active_job) { queue_as "p" } }
      expect { action("GridChild", parent) { async :active_job, queue: "c" } }.to raise_error(ArgumentError, /requires a configuration block/)
    end

    it "sidekiq, same class returning to it with new config" do
      a = action("GridA") { async :sidekiq, queue: "a" }
      a.call_async(name: "x")
      a.async(:active_job) { queue_as "j" }
      a.async :sidekiq, queue: "b"
      expect(outcome { a.call_async(name: "x") }).to eq(%w[sidekiq b])
    end

    it "sidekiq, subclass re-declaring with new config after the parent enqueued" do
      parent = action("GridParent") { async :sidekiq, queue: "p" }
      parent.call_async(name: "x")
      child = action("GridChild", parent) { async :sidekiq, queue: "c" }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[sidekiq c])
      expect(outcome { parent.call_async(name: "x") }).to eq(%w[sidekiq p])
    end

    it "enqueue-all orchestrator returning to active_job with a new block" do
      stub_orchestrator
      orchestrator = Axn::Async::EnqueueAllOrchestrator
      Axn.config.set_enqueue_all_async(:active_job) { queue_as "o1" }
      orchestrator.call_async(target_class_name: "Anything", static_args: {})
      Axn.config.set_enqueue_all_async(:sidekiq, queue: "s")
      Axn.config.set_enqueue_all_async(:active_job) { queue_as "o2" }
      expect(outcome { orchestrator.call_async(target_class_name: "Anything", static_args: {}) }).to eq(%w[active_job o2])
    ensure
      Axn.config.set_enqueue_all_async(nil)
    end

    it "enqueue-all orchestrator returning to sidekiq with new config" do
      stub_orchestrator
      orchestrator = Axn::Async::EnqueueAllOrchestrator
      Axn.config.set_enqueue_all_async(:sidekiq, queue: "o1")
      orchestrator.call_async(target_class_name: "Anything", static_args: {})
      Axn.config.set_enqueue_all_async(:active_job) { queue_as "j" }
      Axn.config.set_enqueue_all_async(:sidekiq, queue: "o2")
      expect(outcome { orchestrator.call_async(target_class_name: "Anything", static_args: {}) }).to eq(%w[sidekiq o2])
    ensure
      Axn.config.set_enqueue_all_async(nil)
    end
  end

  context "with the built-in adapters" do
    it "sidekiq, single-level" do
      a = action("GridA") { async :sidekiq, queue: "a" }
      expect(outcome { a.call_async(name: "x") }).to eq(%w[sidekiq a])
    end

    it "sidekiq, child re-declaring with different config" do
      parent = action("GridParent") { async :sidekiq, queue: "p" }
      child = action("GridChild", parent) { async :sidekiq, queue: "c" }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[sidekiq c])
    end

    it "sidekiq -> active_job -> sidekiq" do
      parent = action("GridParent") { async :sidekiq, queue: "p" }
      child = action("GridChild", parent) { async(:active_job) { queue_as "c" } }
      grandchild = action("GridGrandchild", child) { async :sidekiq, queue: "g" }
      expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[sidekiq g])
    end

    it "sidekiq under an `async false` parent" do
      parent = action("GridParent") { async false }
      child = action("GridChild", parent) { async :sidekiq, queue: "c" }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[sidekiq c])
    end

    it "active_job, single-level" do
      a = action("GridA") { async(:active_job) { queue_as "a" } }
      expect(outcome { a.call_async(name: "x") }).to eq(%w[active_job a])
    end

    it "active_job, child re-declaring with different config" do
      parent = action("GridParent") { async(:active_job) { queue_as "p" } }
      child = action("GridChild", parent) { async(:active_job) { queue_as "c" } }
      expect(outcome { child.call_async(name: "x") }).to eq(%w[active_job c])
    end

    it "active_job -> sidekiq -> active_job" do
      parent = action("GridParent") { async(:active_job) { queue_as "p" } }
      child = action("GridChild", parent) { async :sidekiq, queue: "c" }
      grandchild = action("GridGrandchild", child) { async(:active_job) { queue_as "g" } }
      expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[active_job g])
    end

    it "disabled child of a sidekiq parent" do
      parent = action("GridParent") { async :sidekiq, queue: "p" }
      child = action("GridChild", parent) { async false }
      expect(outcome { child.call_async(name: "x") }).to eq(["raised"])
    end

    it "sidekiq default, inherited" do
      Axn.config.set_default_async(:sidekiq, queue: "d")
      a = action("GridA")
      expect(outcome { a.call_async(name: "x") }).to eq(%w[sidekiq d])
    ensure
      Axn.config.set_default_async(false)
    end
  end

  # Every spelling `async` accepts for an adapter (the registry symbolizes a String or Symbol key; `false` is
  # disabled; nil is the default) must select the same adapter, so nothing downstream may branch on the spelling.
  context "with each accepted spelling of an adapter" do
    def notifications_during
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("axn.call_async") { count += 1 }
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    real_parents = {
      "sidekiq" => proc { async :sidekiq, queue: "p" },
      "active_job" => proc { async(:active_job) { queue_as "p" } },
      "custom" => proc { async :custom, tag: "p" },
    }

    [false, :disabled, "disabled"].each do |spelling|
      real_parents.each do |parent_label, parent_body|
        it "disabled as #{spelling.inspect} under a #{parent_label} parent raises without notifying" do
          register_custom(:class_methods_direct)
          parent = action("GridParent", &parent_body)
          child = action("GridChild", parent) { async spelling }

          result = nil
          expect(notifications_during { result = outcome { child.call_async(name: "x") } }).to eq(0)
          expect(result).to eq(["raised"])
        end
      end

      it "disabled as #{spelling.inspect} under a sidekiq parent is refused by enqueue_all" do
        parent = action("GridParent") { async :sidekiq, queue: "p" }
        child = action("GridChild", parent) { async spelling }

        expect { Axn::Async::EnqueueAllOrchestrator.send(:validate_async_configured!, child) }
          .to raise_error(NotImplementedError, /does not have async configured/)
      end

      it "a default disabled as #{spelling.inspect} is not a configured default, and a class relying on it raises" do
        Axn.config.set_default_async(spelling)
        a = action("GridA")

        expect(Axn.config.default_async?).to be(false)
        expect(outcome { a.call_async(name: "x") }).to eq(["raised"])
      ensure
        Axn.config.set_default_async(false)
      end
    end

    [:sidekiq, "sidekiq"].each do |spelling|
      it "sidekiq as #{spelling.inspect} under an active_job parent" do
        parent = action("GridParent") { async(:active_job) { queue_as "p" } }
        child = action("GridChild", parent) { async spelling, queue: "c" }
        expect(outcome { child.call_async(name: "x") }).to eq(%w[sidekiq c])
      end

      it "sidekiq as #{spelling.inspect}, returning under an active_job child" do
        parent = action("GridParent") { async :sidekiq, queue: "p" }
        child = action("GridChild", parent) { async(:active_job) { queue_as "c" } }
        grandchild = action("GridGrandchild", child) { async spelling, queue: "g" }
        expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[sidekiq g])
      end

      it "sidekiq as #{spelling.inspect}, as the default" do
        Axn.config.set_default_async(spelling, queue: "d")
        a = action("GridA")
        expect(outcome { a.call_async(name: "x") }).to eq(%w[sidekiq d])
      ensure
        Axn.config.set_default_async(false)
      end
    end

    [:active_job, "active_job"].each do |spelling|
      it "active_job as #{spelling.inspect} under a sidekiq parent" do
        parent = action("GridParent") { async :sidekiq, queue: "p" }
        child = action("GridChild", parent) { async(spelling) { queue_as "c" } }
        expect(outcome { child.call_async(name: "x") }).to eq(%w[active_job c])
      end
    end

    # The config setters keep main's split: a raw `false` means "no adapter here" (an enqueue-all override falls
    # back to the default), while `:disabled`/"disabled" names the Disabled adapter explicitly.
    context "when set as the enqueue-all override or the default" do
      before { stub_orchestrator }

      after do
        Axn.config.set_enqueue_all_async(nil)
        Axn.config.set_default_async(false)
      end

      def orchestrator_outcome
        outcome { Axn::Async::EnqueueAllOrchestrator.call_async(target_class_name: "Anything", static_args: {}) }
      end

      [:disabled, "disabled"].each do |spelling|
        it "an enqueue-all override disabled as #{spelling.inspect} beats an enabled default" do
          Axn.config.set_default_async(:sidekiq, queue: "d")
          Axn.config.set_enqueue_all_async(spelling)
          expect(orchestrator_outcome).to eq(["raised"])
        end

        it "a default disabled as #{spelling.inspect} leaves an enqueue-all override in charge" do
          Axn.config.set_enqueue_all_async(:sidekiq, queue: "o")
          Axn.config.set_default_async(spelling)
          expect(orchestrator_outcome).to eq(%w[sidekiq o])
          expect(outcome { action("GridA").call_async(name: "x") }).to eq(["raised"])
        end

        it "a default disabled as #{spelling.inspect}, with no enqueue-all override, disables the orchestrator" do
          Axn.config.set_default_async(:sidekiq, queue: "d")
          Axn.config.set_default_async(spelling)
          expect(orchestrator_outcome).to eq(["raised"])
        end
      end

      it "an enqueue-all override of false is no override, so the enabled default applies" do
        Axn.config.set_default_async(:sidekiq, queue: "d")
        Axn.config.set_enqueue_all_async(false)
        expect(orchestrator_outcome).to eq(%w[sidekiq d])
      end
    end

    [:custom, "custom"].each do |spelling|
      it "a custom adapter as #{spelling.inspect}, returning under an active_job child" do
        register_custom(:class_methods_direct)
        parent = action("GridParent") { async :custom, tag: "p" }
        child = action("GridChild", parent) { async(:active_job) {} }
        grandchild = action("GridGrandchild", child) { async spelling, tag: "g" }
        expect(outcome { grandchild.call_async(name: "x") }).to eq(%w[custom g])
      end
    end
  end
end
