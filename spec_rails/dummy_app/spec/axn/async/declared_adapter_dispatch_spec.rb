# frozen_string_literal: true

# `call_async` enqueues through the adapter a class DECLARES. A class keeps every adapter module it or an ancestor
# ever included and re-including one is a no-op, so plain method lookup would reach whichever adapter was included
# most recently. These cover a registered custom adapter, whose `ClassMethods` may supply `_enqueue_async_job`
# itself or through a module it includes or prepends, on each path that declares an adapter.
RSpec.describe "call_async dispatch through the declared adapter" do
  let(:enqueued) { [] }

  before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }
  after { Axn::Async::Adapters.clear! }

  # The first three styles are a Concern whose ClassMethods supplies the hook: defined in it, or from a module it
  # includes or prepends. The last two have no ClassMethods; the adapter's own `included` hook extends the class
  # with a module that defines the hook, or with one that includes a module defining it.
  def register_custom_adapter(key, style)
    log = enqueued
    hook = Module.new do
      define_method(:_enqueue_async_job) { |_kwargs| log << [key, name] }
      private :_enqueue_async_job
    end
    adapter =
      case style
      when :extended then Module.new { define_singleton_method(:included) { |base| base.extend(hook) } }
      when :extended_via_include
        wrapper = Module.new { include hook }
        Module.new { define_singleton_method(:included) { |base| base.extend(wrapper) } }
      else
        class_methods = Module.new
        case style
        when :direct then class_methods.module_eval { private define_method(:_enqueue_async_job) { |_kwargs| log << [key, name] } }
        when :included then class_methods.include(hook)
        when :prepended then class_methods.prepend(hook)
        end
        Module.new { extend ActiveSupport::Concern }.tap { |concern| concern.const_set(:ClassMethods, class_methods) }
      end
    Axn::Async::Adapters.register(key, adapter)
  end

  def action_class(const_name, superclass = nil, &body)
    klass = superclass ? Class.new(superclass) : build_axn { expects :name }
    klass.class_eval(&body)
    stub_const(const_name, klass)
  end

  %i[direct included prepended extended extended_via_include].each do |style|
    context "with a custom adapter supplying the hook (#{style})" do
      before { register_custom_adapter(:custom, style) }

      it "enqueues a grandchild that returns to the custom adapter under an :active_job child through the custom adapter" do
        parent = action_class("DispatchParent") { async :custom }
        child = action_class("DispatchChild", parent) { async(:active_job) {} }
        grandchild = action_class("DispatchGrandchild", child) { async :custom }

        grandchild.call_async(name: "World")

        expect(enqueued).to eq([[:custom, "DispatchGrandchild"]])
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end

      it "enqueues a class returning to the default custom adapter under an :active_job parent through the custom adapter" do
        allow(Axn.config).to receive(:_apply_async_to_enqueue_all_orchestrator)
        Axn.config.set_default_async(:custom)
        parent = action_class("DispatchDefaultParent") { nil }
        parent.call_async(name: "World")
        child = action_class("DispatchDefaultChild", parent) { async(:active_job) {} }
        grandchild = action_class("DispatchDefaultGrandchild", child) { async }

        grandchild.call_async(name: "World")

        expect(enqueued.last).to eq([:custom, "DispatchDefaultGrandchild"])
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      ensure
        Axn.config.set_default_async(false)
      end

      it "enqueues the enqueue-all orchestrator through the custom adapter after it was switched away and back" do
        stub_const("Axn::Async::EnqueueAllOrchestrator", Class.new(Axn::Async::EnqueueAllOrchestrator))
        Axn.config.set_enqueue_all_async(:custom)
        Axn.config.set_enqueue_all_async(:active_job) {}
        Axn.config.set_enqueue_all_async(:custom)

        Axn::Async::EnqueueAllOrchestrator.call_async(target_class_name: "Anything", static_args: {})

        expect(enqueued).to eq([[:custom, "Axn::Async::EnqueueAllOrchestrator"]])
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      ensure
        Axn.config.set_enqueue_all_async(nil)
      end
    end
  end
end
