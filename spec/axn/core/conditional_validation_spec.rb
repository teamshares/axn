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

    it "leaves other non-Hash validator values under a tolerance flag as a (pre-existing) declaration error" do
      expect do
        build_axn { expects :num, optional: true, numericality: true }
      end.to raise_error(TypeError)
    end
  end

  describe "declaration-level if:/unless: runtime semantics" do
    let(:action) do
      build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: :flag
        def call; end
      end
    end

    it "skips ALL validation (requiredness and type) when the condition is false" do
      expect(action.call(flag: false).ok?).to be true
      expect(action.call(flag: false, num: "junk").ok?).to be true
    end

    it "enforces requiredness and type when the condition is true" do
      failed = action.call(flag: true)
      expect(failed.ok?).to be false
      expect(failed.exception).to be_a(Axn::InboundValidationError)
      expect(action.call(flag: true, num: "junk").ok?).to be false
      expect(action.call(flag: true, num: 5).ok?).to be true
    end

    it "supports the boolean field's generated ? predicate as the Symbol" do
      predicated = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: :flag?
        def call; end
      end
      expect(predicated.call(flag: false).ok?).to be true
      expect(predicated.call(flag: true).ok?).to be false
    end

    it "supports a custom action method and a zero-arity Proc (method calls resolve to the action)" do
      custom = build_axn do
        expects :flag, type: :boolean
        expects :a, type: String, if: :enforce?
        expects :b, type: String, if: -> { flag }
        def enforce? = flag
        def call; end
      end
      expect(custom.call(flag: false).ok?).to be true
      expect(custom.call(flag: true, a: "x", b: "y").ok?).to be true
      expect(custom.call(flag: true, a: "x").ok?).to be false
      expect(custom.call(flag: true, b: "y").ok?).to be false
    end

    it "supports unless: (validates only when falsey) and if:+unless: together (ANDed)" do
      both = build_axn do
        expects :on_flag, :off_flag, type: :boolean
        expects :num, type: Integer, if: :on_flag, unless: :off_flag
        def call; end
      end
      expect(both.call(on_flag: false, off_flag: false).ok?).to be true
      expect(both.call(on_flag: true, off_flag: true).ok?).to be true
      expect(both.call(on_flag: true, off_flag: false).ok?).to be false
    end
  end

  describe "conditions on subfields and exposes" do
    it "gates a subfield's validations (required-when-parent-present pattern)" do
      pending "until the gated-config carve-out (Task 5)"
      action = build_axn do
        expects :data, optional: true
        expects :user, type: String, on: :data, if: -> { data.present? }
        def call; end
      end
      expect(action.call.ok?).to be true                                  # parent omitted
      expect(action.call(data: { user: "kali" }).ok?).to be true
      expect(action.call(data: { role: "admin" }).ok?).to be false        # parent present, user missing
    end

    it "gates an exposes field's outbound validation" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      expect(action.call(flag: false).ok?).to be true                     # nothing exposed, gate closed
      failed = action.call(flag: true)
      expect(failed.ok?).to be false
      expect(failed.exception).to be_a(Axn::OutboundValidationError)
    end
  end

  describe "conditions gate validation only" do
    it "still applies default: and preprocess: when the condition is false" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, default: 42, if: :flag
        expects :name, type: String, preprocess: ->(v) { v.to_s.strip }, allow_nil: true, if: :flag
        exposes :seen_num, :seen_name, allow_nil: true
        def call
          expose seen_num: num, seen_name: name
        end
      end
      result = action.call(flag: false, name: "  kali  ")
      expect(result.ok?).to be true
      expect(result.seen_num).to eq(42)
      expect(result.seen_name).to eq("kali")
    end
  end

  describe "evaluation count" do
    it "may evaluate a declaration-level condition more than once per validation pass (documented; conditions must be cheap/idempotent)" do
      count = 0
      action = build_axn do
        expects :num, type: Integer, if: lambda {
          count += 1
          true
        }
        def call; end
      end
      result = action.call(num: 5)
      expect(result.ok?).to be true
      expect(count).to be >= 1 # AM applies the shared option per validator; exact count is AM-internal
    end
  end

  # NOTE: for the implementer: the Proc above closes over the spec-local `count` variable, which works
  # because instance_exec preserves the closure — no action method needed. If the harness's build_axn
  # block scoping interferes, hoist `count` to an example-group `let` or a module-level accumulator.
  # Assert `>= 1` (and, if stable, the current exact value with a comment that it pins AM internals).

  describe "per-validator nested if: (split validations on one field)" do
    it "gates only the validator carrying the condition" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, numericality: { greater_than: 100, if: :flag }
        def call; end
      end
      expect(action.call(flag: false, num: 5).ok?).to be true
      expect(action.call(flag: true, num: 5).ok?).to be false
      expect(action.call(flag: true, num: 500).ok?).to be true
      expect(action.call(flag: false, num: "junk").ok?).to be false # type still unconditional
    end
  end
end
