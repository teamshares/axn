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

    it "is nil for a name Kernel declares, so axn keeps defining warn" do
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

    # Skipping an axn-core owner has to CONTINUE the walk, not end it. `include Axn` LAST puts axn's own module
    # ahead of the user's in the MRO, so the walk meets the skip before the answer: a skip written as a halt
    # would report no definer here and let axn shadow the user's own method.
    #
    # The name is one axn core declares and does NOT surrender, which is what keeps this example about the skip:
    # for a surrendered name, `include Axn` also installs the deferral shim above the user's module, and the
    # shim — declaring the name, and not axn-core-owned — would be the honest answer to this walk.
    it "continues past an axn-core owner to a user module below it" do
      mod = Module.new { def _run(*) = "USER" }
      action = Class.new do
        include mod
        include Axn
      end

      # Self-checking precondition: something above `mod` declares `_run`, and on this class that can only be axn.
      ancestry = action.ancestors
      expect(ancestry.index { |ancestor| ancestor.instance_methods(false).include?(:_run) }).to be < ancestry.index(mod)

      expect(described_class.inherited_definer(action, :_run)).to eq(mod)
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

  describe ".core_definition_answers?" do
    it "is true when axn's own definition is the one a dispatch would reach" do
      action = Class.new { include Axn }

      expect(described_class.core_definition_answers?(action, :call)).to be true
      expect(described_class.core_definition_answers?(action, :initialize)).to be true
    end

    it "is false for a definition of the class's own, which outranks axn's" do
      action = Class.new do
        include Axn
        def call = nil
      end

      expect(described_class.core_definition_answers?(action, :call)).to be false
    end

    it "is false for a module included after axn's, which sits ahead of them" do
      mine = Module.new { def call = nil }
      action = Class.new do
        include Axn
        include mine
      end

      expect(described_class.core_definition_answers?(action, :call)).to be false
    end

    it "is false for a name nothing in the ancestry declares" do
      expect(described_class.core_definition_answers?(Class.new { include Axn }, :no_such_method)).to be false
    end
  end

  describe ".externally_defined?" do
    it "still answers the class-side question" do
      parent = Class.new { def self.description = "PARENT" }
      expect(described_class.externally_defined?(Class.new(parent), :description)).to be true
      expect(described_class.externally_defined?(Class.new, :description)).to be false
    end
  end

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
end
