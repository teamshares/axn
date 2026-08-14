# frozen_string_literal: true

RSpec.describe Axn::Internal::ActionState do
  describe ".result" do
    it "reaches the real result through a `def result` shadow" do
      klass = build_axn do
        def result = "shadowed"
      end
      action = klass.send(:new)

      expect(action.result).to eq("shadowed")
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "reaches the real result through an `expects :result` reader shadow" do
      klass = build_axn { expects :result }
      action = klass.send(:new, result: 42)

      expect(action.result).to eq(42)
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "preserves memoization (same object across calls)" do
      action = build_axn {}.send(:new)

      expect(described_class.result(action)).to be(described_class.result(action))
    end
  end

  describe ".internal_context" do
    it "reaches the real context through a shadow" do
      klass = build_axn { expects :internal_context }
      action = klass.send(:new, internal_context: "shadowed")

      expect(described_class.internal_context(action)).to be_a(Axn::Core::InternalContext)
    end
  end

  describe ".instance? / .result_or_nil" do
    it "discriminates an action instance from a class, nil, and an unrelated object" do
      klass = build_axn {}

      expect(described_class.instance?(klass.send(:new))).to be true
      expect(described_class.instance?(klass)).to be false
      expect(described_class.instance?(nil)).to be false
      expect(described_class.instance?(Object.new)).to be false
    end

    it "returns nil rather than raising for a non-instance" do
      expect(described_class.result_or_nil(nil)).to be_nil
      expect(described_class.result_or_nil(build_axn {})).to be_nil
    end

    it "is not fooled by an object that merely responds to :result" do
      impostor = Class.new { def result = "not an action" }.new

      expect(impostor).to respond_to(:result)
      expect(described_class.result_or_nil(impostor)).to be_nil
    end
  end
end
