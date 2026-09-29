# frozen_string_literal: true

require "weakref"

# A class that includes Axn must be collectable once nothing outside axn references it. Anything
# process-global that records action classes (the tool registry, a class-keyed cache) has to hold
# them weakly, or every anonymous action — `Class.new { include Axn }`, `Axn::Factory.build`, each
# spec's `build_axn` — lives until the process exits.
#
# GC is not exact: a conservative stack scan can keep a stray object alive. So each surface builds
# several classes inside a thread that has exited before collection (its stack is gone, so nothing
# on it can pin one), and the assertion is "most were collected", which a retaining holder fails by
# a wide margin — it keeps every one.
RSpec.describe "Axn class retention" do
  per_surface = 10

  finder = Struct.new(:id) do
    def self.find(id) = new(id)
  end

  surfaces = {
    "include Axn with expects/exposes" => lambda {
      Class.new do
        include Axn
        expects :x
        exposes :y
        def call = expose(y: x)
      end
    },
    "Axn::Factory.build" => -> { Axn::Factory.build(expects: [:x]) { x } },
    "a subclass of an action" => -> { Class.new(Class.new { include Axn }) },
    "a tool declaration" => lambda {
      Class.new do
        include Axn
        tool
        expects :x
        def call; end
      end
    },
    "a model: field" => lambda {
      Class.new do
        include Axn
        expects :thing, model: { klass: finder }
        def call; end
      end
    },
    "steps, having been called" => lambda {
      Class.new do
        include Axn
        expects :x
        exposes :y
        step(:double, expects: [:x], exposes: [:y]) { expose(y: x * 2) }
      end.tap { |klass| klass.call!(x: 1) }
    },
    "mount_axn, having been called" => lambda {
      Class.new do
        include Axn
        mount_axn(:inner) { |a:| a }
      end.tap { |klass| klass.inner(a: 1) }
    },
    "input_schema/output_schema having been reflected" => lambda {
      Class.new do
        include Axn
        expects :x, type: String
        exposes :y, type: Integer
        def call; end
      end.tap(&:input_schema).tap(&:output_schema)
    },
    "call/call! having been run" => lambda {
      Class.new do
        include Axn
        expects :x
        exposes :y
        def call = expose(y: x)
      end.tap { |klass| klass.call(x: 1) && klass.call!(x: 2) }
    },
    "a failing and a raising call" => lambda {
      Class.new do
        include Axn
        expects :x
        def call = x ? fail!("no") : raise("boom")
      end.tap { |klass| klass.call(x: true) && klass.call(x: false) }
    },
  }

  # One thread builds every surface, then collection runs once for all of them: GC is the cost here,
  # not construction.
  def self.weak_refs_for(surfaces, count)
    Thread.new { surfaces.transform_values { |build| Array.new(count) { WeakRef.new(build.call) } } }.value
  end

  it "collects an unreferenced action class, whatever was declared or run on it" do
    refs = self.class.weak_refs_for(surfaces, per_surface)
    3.times { GC.start(full_mark: true, immediate_sweep: true) }

    alive = refs.transform_values { |weak| weak.count(&:weakref_alive?) }
    expect(alive).to all(satisfy { |_surface, count| count <= per_surface / 2 })
  end

  describe "classes still referenced" do
    before { Axn::Tools.register_adapter(:retention_spec) }

    # The constant is the only strong reference: no local holds the class across the collection, so
    # a holder that loses live entries (not just dead ones) fails here.
    it "keeps a class reachable through its constant enumerable" do
      stub_const("ClassRetentionSpec::Named", Class.new { include Axn })
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      expect(Axn::Tools::Registry.all_classes).to include(ClassRetentionSpec::Named)
    end

    it "keeps a registered tool discoverable" do
      stub_const("ClassRetentionSpec::Tool", Class.new do
        include Axn
        tool :retention_spec
        def call; end
      end)
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      expect(Axn::Tools.for(:retention_spec)).to include(ClassRetentionSpec::Tool)
    end
  end
end
