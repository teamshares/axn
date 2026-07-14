# frozen_string_literal: true

RSpec.describe "conditional validation declarations (if:/unless:)" do
  describe "tolerance flags + declaration-level condition" do
    it "declares and runs (condition gates validators; tolerance keeps the field omittable)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :note, type: String, optional: true, if: :flag
        def call; end
      end

      expect(action.call(flag: false).ok?).to be true                 # omitted, tolerance
      expect(action.call(flag: false, note: 123).ok?).to be true      # type gated off
      expect(action.call(flag: true).ok?).to be true                  # still omittable (optional:)
      expect(action.call(flag: true, note: 123).ok?).to be false      # type enforced, blank-tolerant
      expect(action.call(flag: true, note: "hi").ok?).to be true
    end

    it "declares cleanly when the tolerance leaves no validators at all" do
      action = build_axn do
        expects :note, optional: true, if: :never
        def never = false
        def call; end
      end

      expect(action.call.ok?).to be true
      expect(action.call(note: "anything").ok?).to be true
    end
  end

  describe "tolerance flags + explicit presence:" do
    it "rejects optional: + presence: true with a clear declaration error" do
      expect do
        build_axn { expects :note, optional: true, presence: true }
      end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
    end

    it "rejects allow_nil: + a per-validator conditional presence (the tolerance would neuter it)" do
      expect do
        build_axn { expects :note, allow_nil: true, presence: { if: :cond } }
      end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
    end

    it "still allows presence: false alongside a tolerance flag (explicit suppression, coherent)" do
      expect { build_axn { expects :note, optional: true, presence: false } }.not_to raise_error
    end
  end
end
