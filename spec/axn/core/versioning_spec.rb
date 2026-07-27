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
  end

  describe "setter" do
    it "stores the declared version and reads it back" do
      k = tool_klass
      k.tool_version(2)
      expect(k.tool_version).to eq(2)
      expect(k._tool_version).to eq(2)
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

    # The removed `default:` pin option. `tool_version` takes no keywords (`**nil`), so both forms
    # raise the plain unknown-option error a removed kwarg should — NOT the bespoke Integer message,
    # which a lone keyword would otherwise reach by binding to `value` as a positional Hash.
    it "rejects the removed default: option as an unknown keyword, not a bad version" do
      expect { tool_klass.tool_version(2, default: true) }.to raise_error(ArgumentError, /no keywords accepted/)

      # The lone-keyword form is the one that regresses silently: it binds to `value` as a positional
      # Hash, so assert the bespoke Integer message is genuinely absent, not merely that it raised.
      expect { tool_klass.tool_version(default: true) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include("no keywords accepted")
        expect(error.message).not_to match(/Integer >= 1/)
      end
    end
  end

  describe "_tool_version_suffix (single source for parsing the ::Vn constant segment)" do
    it "returns the number for a vN-suffixed constant" do
      expect(tool_klass("AgentTools::Approve::V2")._tool_version_suffix).to eq(2)
    end

    it "handles multi-digit versions" do
      expect(tool_klass("AgentTools::Approve::V10")._tool_version_suffix).to eq(10)
    end

    it "is nil for a non-vN trailing segment" do
      expect(tool_klass("AgentTools::ApproveV2")._tool_version_suffix).to be_nil
      expect(tool_klass("AgentTools::Approve")._tool_version_suffix).to be_nil
    end

    it "is nil for an anonymous class" do
      expect(tool_klass._tool_version_suffix).to be_nil
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
