# frozen_string_literal: true

RSpec.describe Axn::Core::Versioning do
  # Anonymous-class-safe builder; optionally stamps a constant name so the
  # ::Vn mismatch guard (which reads `self.name`) can be exercised.
  def tool_klass(const_name = nil)
    Class.new do
      include Axn
      define_singleton_method(:name) { const_name } if const_name
    end
  end

  describe "reader default" do
    it "is 1 when never declared" do
      expect(tool_klass.tool_version).to eq(1)
    end

    it "is not flagged the explicit default when never declared" do
      expect(tool_klass._tool_version_default).to be(false)
    end
  end

  describe "setter" do
    it "stores the declared version and reads it back" do
      k = tool_klass
      k.tool_version(2)
      expect(k.tool_version).to eq(2)
      expect(k._tool_version).to eq(2)
    end

    it "records the default: flag" do
      k = tool_klass
      k.tool_version(2, default: true)
      expect(k._tool_version_default).to be(true)
    end

    it "defaults the default: flag to false" do
      k = tool_klass
      k.tool_version(2)
      expect(k._tool_version_default).to be(false)
    end
  end

  describe "validation" do
    it "rejects zero" do
      expect { tool_klass.tool_version(0) }.to raise_error(ArgumentError, /Integer >= 1/)
    end

    it "rejects negatives" do
      expect { tool_klass.tool_version(-1) }.to raise_error(ArgumentError, /Integer >= 1/)
    end

    it "rejects non-Integers" do
      expect { tool_klass.tool_version("2") }.to raise_error(ArgumentError, /Integer >= 1/)
    end

    it "rejects a truthy non-boolean default: (e.g. the string \"false\")" do
      expect { tool_klass.tool_version(2, default: "false") }.to raise_error(ArgumentError, /default.*true or false/)
    end

    it "rejects a nil default:" do
      expect { tool_klass.tool_version(2, default: nil) }.to raise_error(ArgumentError, /default.*true or false/)
    end
  end

  describe "declared-here vs inherited" do
    it "marks the declaring class but not an inheriting subclass" do
      base = Class.new do
        include Axn
        tool_version 1
      end
      sub = Class.new(base)

      expect(base._tool_version_declared_here?).to be(true)
      expect(sub._tool_version_declared_here?).to be(false)
      # The subclass still inherits the effective version value...
      expect(sub.tool_version).to eq(1)
      # ...but is not treated as having declared its own.
    end
  end

  describe "::Vn mismatch guard" do
    it "raises when the constant segment number disagrees with the declared version" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      expect { k.tool_version(3) }.to raise_error(ArgumentError, /::V2.*tool_version 3/)
    end

    it "accepts a matching ::Vn segment" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      expect { k.tool_version(2) }.not_to raise_error
      expect(k.tool_version).to eq(2)
    end

    it "is skipped for an anonymous class (no constant name)" do
      k = tool_klass # name is nil
      expect { k.tool_version(2) }.not_to raise_error
    end

    it "ignores a trailing segment that is not the exact vN pattern" do
      k = tool_klass("AgentTools::ApproveLoanV2") # not a ::Vn segment
      expect { k.tool_version(3) }.not_to raise_error
    end
  end
end
