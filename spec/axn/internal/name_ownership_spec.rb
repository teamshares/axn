# frozen_string_literal: true

RSpec.describe Axn::Internal::NameOwnership do
  let(:action) { build_axn }

  describe ".conflict_for" do
    it "is nil for a name nothing owns" do
      expect(described_class.conflict_for(action, :widget)).to be_nil
    end

    it "is nil for axn's own sugar, which a declaration may take" do
      expect(described_class.conflict_for(action, :result)).to be_nil
      expect(described_class.conflict_for(action, :log)).to be_nil
    end

    it "names Ruby as the owner of a name Ruby holds" do
      expect(described_class.conflict_for(action, :hash)).to eq(Kernel)
    end

    it "names the action's own class for a method the author wrote" do
      klass = build_axn { def helper = "mine" }

      expect(described_class.conflict_for(klass, :helper)).to eq(klass)
    end

    it "reports the entry points as unsurrenderable rather than naming an owner" do
      expect(described_class.conflict_for(action, :call)).to eq(:unsurrenderable)
      expect(described_class.conflict_for(action, :initialize)).to eq(:unsurrenderable)
    end

    # A sugar module holds axn's internals alongside its sugar, and only the sugar is on offer.
    it "reports an underscored member of a sugar module as internal" do
      expect(described_class.conflict_for(action, :_build_context_facade)).to eq(:internal)
    end

    it "leaves an underscored name NO sugar module owns free" do
      expect(described_class.conflict_for(action, :_widget)).to be_nil
    end

    it "accepts a String as readily as a Symbol" do
      expect(described_class.conflict_for(action, "hash")).to eq(Kernel)
    end
  end

  describe ".owner_within" do
    it "names an owner the class itself contributes" do
      expect(described_class.owner_within(Axn::Core::InternalContext, :default_error))
        .to eq(Axn::Core::InternalContext)
    end

    it "reaches an owner inherited from below the boundary" do
      expect(described_class.owner_within(Axn::Core::InternalContext, :declared_fields))
        .to eq(Axn::Core::ContextFacade)
    end

    # Ruby's universal methods are judged on the action class instead, so asking a second receiver
    # about them would refuse names axn's own sugar owns there.
    it "is nil for a name only Object or Kernel owns" do
      expect(described_class.owner_within(Axn::Core::InternalContext, :warn)).to be_nil
      expect(described_class.owner_within(Axn::Core::InternalContext, :class)).to be_nil
    end
  end

  describe ".describe" do
    it "names the owning module for an ordinary conflict" do
      expect(described_class.describe(Kernel)).to include("Kernel")
    end

    it "explains an unsurrenderable name without naming an owner" do
      expect(described_class.describe(:unsurrenderable)).to include("axn itself")
    end
  end
end
