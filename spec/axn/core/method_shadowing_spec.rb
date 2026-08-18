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
      parent = Class.new { include mod }
      expect(described_class.inherited_definer(Class.new(parent), :log)).to eq(mod)
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
