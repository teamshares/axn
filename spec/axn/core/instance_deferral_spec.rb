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
end
