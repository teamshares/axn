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
end
