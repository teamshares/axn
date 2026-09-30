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
        stub_const("Axn::Async::EnqueueAllOrchestrator", Class.new(Axn::Async::EnqueueAllOrchestrator))
        Axn.config.set_enqueue_all_async(:custom, tag: "o1")
        Axn.config.set_enqueue_all_async(:active_job) {}
        Axn.config.set_enqueue_all_async(:custom, tag: "o2")
        orchestrator = Axn::Async::EnqueueAllOrchestrator
        expect(outcome { orchestrator.call_async(target_class_name: "Anything", static_args: {}) }).to eq(%w[custom o2])
      ensure
        Axn.config.set_enqueue_all_async(nil)
      end
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
end
