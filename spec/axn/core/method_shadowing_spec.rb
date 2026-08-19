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

    # `undef_method` writes an entry no own-table read reports, while a lookup arriving from below stops dead
    # on it — so a walk over own tables alone reports a definition that no dispatch could reach.
    it "stops at an undef_method barrier rather than naming a definition it makes unreachable" do
      distant = Class.new { def log(*) = "DISTANT" }
      barrier = Class.new(distant) { undef_method :log }

      expect { barrier.new.log }.to raise_error(NoMethodError)
      expect(described_class.inherited_definer(Class.new(barrier), :log)).to be_nil
    end

    # A module hosts the barrier as readily as a class does, and nothing distinguishes its undef entry from the
    # absence of a declaration in its own table — so the barrier has to be read off the chain as a whole.
    it "stops at a barrier a module contributes" do
      distant = Class.new { def log(*) = "DISTANT" }
      undeffer = Module.new do
        def log(*) = "MOD"
        undef_method :log
      end
      barrier = Class.new(distant) { include undeffer }

      expect { barrier.new.log }.to raise_error(NoMethodError)
      expect(described_class.inherited_definer(barrier, :log)).to be_nil
      expect(described_class.inherited_definer(Class.new(barrier), :log)).to be_nil
    end

    # The barrier record `include Axn` takes cannot see this one: it was taken before the undef existed. An
    # ancestor CLASS's own lookup is not masked by the modules axn includes into the action beneath it, so it
    # is still readable live — which is what catches a barrier added afterwards.
    it "stops at a barrier an ancestor class gained after the include recorded the chain" do
      distant = Class.new
      barrier = Class.new(distant)
      action = Class.new(barrier) { include Axn }

      distant.class_eval { def log(*) = "DISTANT" }
      barrier.send(:undef_method, :log)

      expect { Class.new(barrier).new.log }.to raise_error(NoMethodError)
      expect(described_class.inherited_definer(action, :log)).to be_nil
    end

    # The other direction of the same read: a barrier that a nearer class re-declares over is no barrier at all
    # for anything below it, and ending the walk at the first unreachable-looking ancestor would drop a definer
    # a dispatch really does arrive at.
    it "keeps naming a definer below a barrier that a nearer class re-declared over" do
      distant = Class.new { def log(*) = "DISTANT" }
      barrier = Class.new(distant) { undef_method :log }
      nearer = Class.new(barrier) { def log(*) = "NEARER" }

      expect(nearer.new.log).to eq("NEARER")
      expect(described_class.inherited_definer(Class.new(nearer), :log)).to eq(nearer)
    end

    # An own-table declaration a PREPENDED module undefs is unreachable from below just as an inherited one is,
    # so the barrier is read before the own-table question rather than after it. Prepended after the include,
    # where the record cannot see it and the live read is the only reader left.
    it "stops at a barrier prepended over the declaring class's own definition" do
      distant = Class.new { def call = "DISTANT" }
      barrier = Class.new(distant) { def call = "OWN" }
      action = Class.new(barrier) { include Axn }

      barrier.prepend(Module.new do
        def call = "PRE"
        undef_method :call
      end)

      expect { Class.new(barrier).new.call }.to raise_error(NoMethodError)
      expect(described_class.inherited_definer(action, :call)).to be_nil
    end

    it "keeps naming a definer above a barrier for a name the barrier left alone" do
      distant = Class.new do
        def log(*) = "DISTANT"
        def info(*) = "DISTANT-INFO"
      end
      barrier = Class.new(distant) { undef_method :log }

      expect(described_class.inherited_definer(Class.new(barrier), :info)).to eq(distant)
    end

    # The barrier is read off effective lookup on the CLASS BEING ASKED ABOUT, once, before the walk. Read
    # per-ancestor instead, this module — which simply does not declare the name — would answer the same nil a
    # barrier does and end the walk before it reached the parent.
    it "walks through a module that declares nothing" do
      parent = Class.new { def log(*) = "PARENT" }
      child = Class.new(parent) { include Module.new }

      expect(described_class.inherited_definer(Class.new(child), :log)).to eq(parent)
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

    # The shape a re-walk of own tables gets wrong, and the reason this predicate reads the EFFECTIVE owner: the
    # class's own table is empty, so an own-table reading finds nothing of the user's and concludes axn answers —
    # which inside `assert_dispatchable_names_free!` is a wrong raise against a superclass. The prepended module
    # is what a call would actually reach.
    it "is false for a module prepended to a class that declares nothing of its own" do
      mine = Module.new { def call = nil }
      action = Class.new do
        include Axn
        prepend mine
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
