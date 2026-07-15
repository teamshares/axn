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

  # A non-Hash scalar validator value (`numericality: true`, `inclusion: [..]`/`1..5`, `format: /re/`)
  # normalizes exactly as ActiveModel's own `validates` would, then the tolerance rides on top — so the
  # terse spelling combines transparently with optional:/allow_blank:/allow_nil: (PRO-2915). Previously
  # this raised a bare `TypeError` from the tolerance push-down loop.
  describe "tolerance flags + non-Hash scalar validator values" do
    it "normalizes `numericality: true` and applies the tolerance" do
      action = build_axn do
        expects :num, numericality: true, optional: true
        def call; end
      end

      expect(action.call.ok?).to be true              # omitted (tolerance)
      expect(action.call(num: 5).ok?).to be true      # numericality satisfied
      expect(action.call(num: "nope").ok?).to be false # numericality enforced
    end

    it "normalizes an Array value to `in:` (inclusion) and applies the tolerance" do
      action = build_axn do
        expects :color, inclusion: %w[red green], optional: true
        def call; end
      end

      expect(action.call.ok?).to be true
      expect(action.call(color: "red").ok?).to be true
      expect(action.call(color: "blue").ok?).to be false
    end

    it "normalizes a Range value to `in:` (inclusion) and applies the tolerance" do
      action = build_axn do
        expects :n, inclusion: 1..5, optional: true
        def call; end
      end

      expect(action.call.ok?).to be true
      expect(action.call(n: 3).ok?).to be true
      expect(action.call(n: 9).ok?).to be false
    end

    it "normalizes a Regexp value to `with:` (format) and applies the tolerance" do
      action = build_axn do
        expects :code, format: /\A\d+\z/, optional: true
        def call; end
      end

      expect(action.call.ok?).to be true
      expect(action.call(code: "123").ok?).to be true
      expect(action.call(code: "abc").ok?).to be false
    end

    it "treats a falsy validator value as disabled (mirrors ActiveModel's falsy-skip)" do
      expect { build_axn { expects :num, numericality: nil, optional: true } }.not_to raise_error
      expect { build_axn { expects :num, numericality: false, optional: true } }.not_to raise_error

      action = build_axn do
        expects :num, numericality: false, optional: true
        def call; end
      end
      expect(action.call(num: "not-a-number").ok?).to be true # numericality disabled
    end

    it "keeps a nil-disabled validator OUT of input_schema[:required] (matches its omittable runtime)" do
      action = build_axn do
        expects :num, numericality: nil, optional: true
        def call; end
      end

      expect(action.call.ok?).to be true # omittable at runtime
      expect(action.input_schema[:required] || []).not_to include(:num, "num")
    end

    # `strict:` is an ActiveModel SHARED option, not a validator — the push-down must leave it intact
    # rather than normalize it into an options hash (which would raise a bare `TypeError` at
    # strict-raise time instead of the strict exception).
    it "preserves strict: under a tolerance flag (raises the strict exception, not a TypeError)" do
      action = build_axn do
        expects :num, numericality: true, optional: true, strict: true
        def call; end
      end

      expect(action.call.ok?).to be true # omittable (tolerance intact)
      result = action.call(num: "nope")
      expect(result.ok?).to be false
      expect(result.exception).to be_a(ActiveModel::StrictValidationFailed)

      # The restored strict: is a shared option, not a validator — reflection must not read it as a
      # nil-rejecting validator and mark the (omittable) field required.
      expect(action.input_schema[:required] || []).not_to include(:num, "num")
      expect(action.input_schema.dig(:properties, :num, :type)).to contain_exactly("number", "null")
    end

    it "reflects a normalized scalar validator identically to its Hash form under a tolerance flag" do
      action = build_axn do
        expects :num, numericality: true, optional: true
        expects :n2, numericality: { greater_than: 0 }, optional: true
        def call; end
      end

      props = action.input_schema.fetch(:properties)
      expect(props.fetch(:num)).to eq(props.fetch(:n2))
      expect(props.dig(:num, :type)).to contain_exactly("number", "null")
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
      action = build_axn do
        expects :data, optional: true
        expects :user, type: String, on: :data, if: -> { data.present? }
        def call; end
      end
      expect(action.call.ok?).to be true                                  # parent omitted
      expect(action.call(data: { user: "kali" }).ok?).to be true
      expect(action.call(data: { role: "admin" }).ok?).to be false        # parent present, user missing
    end

    it "gates a subfield's PRESENCE via a per-validator (nested) condition (required-when-parent-present)" do
      # The nested `presence: { if: ... }` form is the other blessed tier: the presence check is the
      # only thing gated, so an omitted parent skips it and the call validates, while a present parent
      # without the subfield fails. The reflection layer must accept this at declaration (Finding A).
      action = build_axn do
        expects :data, optional: true
        expects :user, on: :data, presence: { if: -> { data.present? } }
        def call; end
      end
      expect(action.call.ok?).to be true                                  # parent omitted → gate closed
      expect(action.call(data: { user: "kali" }).ok?).to be true
      expect(action.call(data: { role: "admin" }).ok?).to be false        # parent present, user missing
    end

    it "still rejects a nested-gated presence sitting alongside an UNGATED nil-rejecting check under an optional parent" do
      # Only a FULLY-relaxable subfield relaxes: the ungated `type: String` can still reject a nil
      # `user` when `data` is present-but-userless, so the dead-tolerance contradiction stands.
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, on: :data, type: String, presence: { if: -> { data.present? } }
          def call; end
        end
      end.to raise_error(ArgumentError, /tolerance can never be exercised/)
    end

    it "gates an exposes field's outbound validation" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      expect(action.call(flag: false).ok?).to be true # nothing exposed, gate closed
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

  # AM merges the declaration-level shared gate with each entry's nested gate PER KEY (measured
  # precedence, activemodel 7.2.2.2): the entry's own key overrides the shared one, distinct keys AND
  # together, and a BLANK nested value drops the shared gate for that key and is then ignored. These
  # pin the runtime truth reflection models structurally (Codex round 14).
  describe "per-key merge of a declaration gate with a blank nested override" do
    it "runs the nil-rejecting check UNCONDITIONALLY when a blank same-key nested override drops the shared gate" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :name, type: String, if: :flag, presence: { if: nil }
        def call; end
      end
      # `presence: { if: nil }` overrides+drops `if: :flag` for presence, so presence runs regardless of
      # flag — name is required for every call (schema reflects it unconditionally required, no allOf).
      expect(action.call(flag: false).ok?).to be false
      expect(action.call(flag: true).ok?).to be false
      expect(action.call(flag: false, name: "x").ok?).to be true
    end

    it "keeps a DISTINCT-key declaration gate when a blank nested override drops only the same key" do
      action = build_axn do
        expects :flag, type: :boolean, default: false
        expects :data, optional: true
        expects :user, on: :data, unless: :flag, presence: { if: nil }
        def call; end
      end
      # Blank nested `if:` dropped; distinct `unless: :flag` still gates presence. So `:data` may be
      # omitted when the gate is CLOSED (flag truthy), and presence runs when it is OPEN (flag falsey).
      expect(action.call(flag: true).ok?).to be true
      expect(action.call(flag: false).ok?).to be false
      expect(action.call(flag: false, data: { user: "x" }).ok?).to be true
    end
  end

  describe "shape members (action-scoped conditions and Symbol args)" do
    it "resolves a member's Symbol validator argument against the action" do
      action = build_axn do
        expects :payload, type: Hash do
          field :status, type: String, inclusion: { in: :allowed_statuses }
        end
        def allowed_statuses = %w[open closed]
        def call; end
      end
      expect(action.call(payload: { status: "open" }).ok?).to be true
      expect(action.call(payload: { status: "bogus" }).ok?).to be false
    end

    it "gates a member's validations on an action-scoped if: condition" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, type: String, if: :flag
        end
        def call; end
      end
      # `payload` itself defaults to `presence: true` (like any field, an empty Hash counts as
      # blank) — orthogonal to `note`'s gate, so these calls use a non-blank stand-in key rather
      # than `{}` to isolate what's under test: the member's OWN if:-gated requiredness.
      expect(action.call(flag: false, payload: { unused: true }).ok?).to be true
      expect(action.call(flag: false, payload: { note: 123 }).ok?).to be true
      expect(action.call(flag: true, payload: { unused: true }).ok?).to be false
      expect(action.call(flag: true, payload: { note: "hi" }).ok?).to be true
    end

    it "resolves conditions on NESTED members (the member's validator carries the action down)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :meta, type: Hash do
            field :note, type: String, if: :flag
          end
        end
        def call; end
      end
      # Same non-blank stand-in as above, one level down: `meta` also defaults to `presence: true`.
      expect(action.call(flag: false, payload: { meta: { unused: true } }).ok?).to be true
      expect(action.call(flag: true, payload: { meta: { unused: true } }).ok?).to be false
    end

    it "does NOT expose element data to conditions (action-scoped only — element scoping is a non-goal)" do
      action = build_axn do
        expects :items, type: Array do
          field :b, type: String, if: -> { a } # `a` is a sibling MEMBER, not an action method
        end
        def call; end
      end
      result = action.call(items: [{ "a" => true }])
      expect(result.ok?).to be false
      # The if: proc is instance_exec'd against the one-off validator (never the array element), so
      # bare `a` is looked up there first as a local/method call: absent locally, method_missing
      # delegates to the action, which also doesn't define `a`. Ruby classifies a bare-identifier
      # miss (no explicit receiver, no args) as NameError rather than NoMethodError — pinning the
      # observed class here; the contract under test is that it does NOT silently resolve against
      # the element, not the exact exception subclass.
      expect(result.exception).to be_a(NameError)
    end
  end

  # A closed declaration-level gate means the declaration is WHOLLY unvalidated. Two axn-side checks
  # live OUTSIDE ActiveModel and must honor the gate too (Codex round 4): the executor's model
  # record/id consistency pass, and ShapeValidator's unreadable-member pre-check. Both route through
  # the one gate oracle (Fields.declaration_gate_open?), which asks ActiveModel itself.
  describe "closed gate also waives the model-consistency check (outside ActiveModel)" do
    # Plain PORO with a pk finder, so this runs outside Rails (mirrors model_id_reader_spec).
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
      end
    end

    it "skips the record/id mismatch when a Symbol gate is CLOSED, but keeps it when OPEN" do
      klass = co_class
      action = build_axn do
        expects :flag, type: :boolean
        expects :company, model: { klass:, finder: :find }, if: :flag
        def call; end
      end

      # gate CLOSED: the whole company declaration is waived, so the record/id conflict is not a
      # mismatch (the model validator itself is gated off too) — the call succeeds.
      expect(action.call(flag: false, company: klass.new(5), company_id: 9)).to be_ok

      # gate OPEN: the mismatch is preserved — same conflict now pages.
      opened = action.call(flag: true, company: klass.new(5), company_id: 9)
      expect(opened).not_to be_ok
      expect(opened.exception).to be_a(Axn::InboundValidationError)
      expect(opened.exception.message).to match(/conflicts with company_id=9/)
    end

    it "skips the record/id mismatch when a Proc gate is CLOSED" do
      klass = co_class
      action = build_axn do
        expects :company, model: { klass:, finder: :find }, if: -> { false }
        def call; end
      end

      expect(action.call(company: klass.new(5), company_id: 9)).to be_ok
    end

    it "honors a CLOSED gate on a subfield model config (mismatch under a gated subfield is waived)" do
      klass = co_class
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload
        expects :company, on: :payload, model: { klass:, finder: :find }, if: :flag
        def call; end
      end

      expect(action.call(flag: false, payload: { company: klass.new(5), company_id: 9 })).to be_ok

      opened = action.call(flag: true, payload: { company: klass.new(5), company_id: 9 })
      expect(opened).not_to be_ok
      expect(opened.exception).to be_a(Axn::InboundValidationError)
    end

    it "still raises the mismatch for an UNGATED model config (pins zero regression)" do
      klass = co_class
      action = build_axn do
        expects :company, model: { klass:, finder: :find }
        def call; end
      end

      result = action.call(company: klass.new(5), company_id: 9)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to match(/conflicts with company_id=9/)
    end

    # The gate can also live NESTED inside the model: hash (a per-validator gate, the other blessed
    # tier) rather than at the declaration level. AM skips the ModelValidator when that nested gate is
    # closed, so the outside-AM model-consistency pass must skip too (Codex round 11).
    it "skips the mismatch when the model:'s OWN nested gate is CLOSED, keeps it when OPEN" do
      klass = co_class
      action = build_axn do
        expects :flag, type: :boolean
        expects :company, model: { klass:, finder: :find, if: :flag }
        def call; end
      end

      expect(action.call(flag: false, company: klass.new(5), company_id: 9)).to be_ok

      opened = action.call(flag: true, company: klass.new(5), company_id: 9)
      expect(opened).not_to be_ok
      expect(opened.exception).to be_a(Axn::InboundValidationError)
      expect(opened.exception.message).to match(/conflicts with company_id=9/)
    end

    # BOTH tiers present on one model field: a declaration-level shared gate AND a nested gate on the
    # model: hash. AM's real precedence decides which runs — don't hardcode a winner. Instead pin that
    # our outside-AM skip AGREES with whether the MODEL validator actually ran, observed on the SAME
    # declaration. The signal isolates the ModelValidator (not the auto-injected presence, which the
    # consistency check is orthogonal to): a PRESENT-but-invalid value (`company: Object.new`) passes
    # presence and fails IFF the ModelValidator runs ("is not a Co"). Our record/id conflict must then
    # raise IFF that same ModelValidator ran.
    it "agrees with AM's real tier precedence when BOTH a shared and a nested gate are present" do
      klass = co_class
      # Distinct flags so the two tiers can disagree; AM's merge (nested key overrides shared key)
      # then decides, and both the ModelValidator run and our mismatch skip must follow the SAME call.
      [[false, false], [false, true], [true, false], [true, true]].each do |shared_on, nested_on|
        action = build_axn do
          expects :shared_flag, :nested_flag, type: :boolean
          expects :company, model: { klass:, finder: :find, if: :nested_flag }, if: :shared_flag
          def call; end
        end

        model_ran = !action.call(shared_flag: shared_on, nested_flag: nested_on, company: Object.new).ok?

        conflict = action.call(shared_flag: shared_on, nested_flag: nested_on, company: klass.new(5), company_id: 9)
        expect(conflict.ok?).to eq(!model_ran),
                                "shared=#{shared_on} nested=#{nested_on}: model_ran=#{model_ran} but conflict.ok?=#{conflict.ok?}"
      end
    end
  end

  describe "closed gate also waives ShapeValidator's unreadable-member pre-check" do
    # An Array container validates every element regardless of type, so a scalar element is a
    # non-Hash shaped value lacking the declared member reader — the case the pre-check guards.
    it "suppresses the could-not-be-read error when the member's gate is CLOSED" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, type: String, if: :flag
        end
        def call; end
      end

      expect(action.call(flag: false, items: [42])).to be_ok
    end

    it "fires the could-not-be-read error when the member's gate is OPEN" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, type: String, if: :flag
        end
        def call; end
      end

      result = action.call(flag: true, items: [42])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0: note could not be read \(got Integer\)/)
    end

    it "fires the could-not-be-read error for an UNGATED member (pins zero regression)" do
      action = build_axn do
        expects :items, type: Array do
          field :note, type: String
        end
        def call; end
      end

      result = action.call(items: [42])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0: note could not be read/)
    end

    it "was already fine for an extractable (Hash) source with a closed gate (AM skips the gated validator)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, type: String, if: :flag
        end
        def call; end
      end

      # A Hash element IS extractable (dig by key), so the read happens and AM itself skips the
      # gated `note` validators — no unreadable-member pre-check involved.
      expect(action.call(flag: false, items: [{ other: 1 }])).to be_ok
    end

    # Codex's exact shape: the gate is NESTED on a single validator entry (`presence: { if: :flag }`),
    # not at the member's declaration level. AM merges/evaluates it per validator, so the unreadable
    # pre-check must honor it too (Codex round 11).
    it "suppresses the could-not-be-read error when the member's only entry carries a CLOSED nested gate" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, presence: { if: :flag }
        end
        def call; end
      end

      expect(action.call(flag: false, items: [42])).to be_ok
    end

    it "fires the could-not-be-read error when the member's only entry carries an OPEN nested gate" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, presence: { if: :flag }
        end
        def call; end
      end

      result = action.call(flag: true, items: [42])
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/element at index 0: note could not be read \(got Integer\)/)
    end

    # A member with one GATED entry and one UNGATED entry on a non-extractable element: the ungated
    # entry always runs, so the read matters regardless of the gated entry's state — the error fires
    # whether or not the gated entry's condition is open (any single open entry keeps the error).
    it "fires the could-not-be-read error when a member has an ungated entry alongside a gated one" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :items, type: Array do
          field :note, type: String, presence: { if: :flag }
        end
        def call; end
      end

      [true, false].each do |flag|
        result = action.call(flag:, items: [42])
        expect(result).not_to be_ok, "flag=#{flag}: expected the ungated type: entry to keep the error"
        expect(result.exception.message).to match(/element at index 0: note could not be read/)
      end
    end
  end

  describe "shared gate oracle (ActiveModel itself decides — no hand-rolled mirror)" do
    it "resolves a Symbol gate through the action (exercised by both outside-AM checks)" do
      klass = Class.new do
        def self.name = "Co"
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
      end
      action = build_axn do
        expects :company, model: { klass:, finder: :find }, if: :gate_open?
        def gate_open? = false
        def call; end
      end

      # :gate_open? resolves against the action (via method_missing on the one-off validator) → the
      # model-consistency check is waived even with a conflicting record/id.
      expect(action.call(company: klass.new(5), company_id: 9)).to be_ok
    end

    it "propagates a raising gate condition as the call's exception (matches raising inside AM validation)" do
      # A gate that raises surfaces as result.exception of the raised class — the same behavior as a
      # condition that raises during a normal valid? pass (verified: an AM-path raise surfaces
      # identically). Here the non-extractable shape-member path routes exclusively through the
      # shared helper (AM never runs, the element isn't extractable), so this pins the helper itself.
      boom = Class.new(StandardError)
      action = build_axn do
        # `boom` is closed over by the Proc (instance_exec preserves the closure — same mechanism as
        # the evaluation-count example above), so no action method or constant lookup is needed.
        expects :items, type: Array do
          field :note, type: String, if: -> { raise boom, "gate boom" }
        end
        def call; end
      end

      result = action.call(items: [42])
      expect(result).not_to be_ok
      expect(result.exception).to be_a(boom)
      expect(result.exception.message).to eq("gate boom")
    end
  end

  # The set of "blank" condition values ActiveModel IGNORES (runs the validators unconditionally) is
  # measured against the bundled activemodel 7.2.2.2, not guessed: `check_conditionals` early-returns
  # an empty condition list `if conditionals.blank?`, so `nil`, `false`, `""`, any whitespace-only
  # String, and `[]` are each NO conditional at all. axn canonicalizes exactly that set away with the
  # same `value.blank?` predicate, so a remaining gate key always denotes a real, enforced gate.
  describe "blank gate values (AM-ignored conditions canonicalize away — a blank gate is no gate)" do
    it "rejects a nil-tolerant parent whose required subfield carries `if: nil`, exactly as if if: were absent" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data, if: nil
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "rejects the same dead-tolerance shape for `if: false` and `if: \"\"` (both blank, hence no gate)" do
      [false, ""].each do |blank|
        expect do
          build_axn do
            expects :data, optional: true
            expects :user, type: String, on: :data, if: blank
          end
        end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
      end
    end

    it "still enforces a field declared with `if: nil` unconditionally at runtime" do
      action = build_axn do
        expects :num, type: Integer, if: nil
        def call; end
      end
      omitted = action.call
      expect(omitted.ok?).to be false
      expect(omitted.exception).to be_a(Axn::InboundValidationError)
      expect(action.call(num: 5).ok?).to be true
    end

    it "enforces `if: false`/`if: \"\"`/`if: \" \"` unconditionally at runtime (blank == no gate, NOT never-run)" do
      [false, "", " "].each do |blank|
        action = build_axn do
          expects :num, type: Integer, if: blank
          def call; end
        end
        expect(action.call.ok?).to be false # required, gate absent
        expect(action.call(num: 5).ok?).to be true
      end
    end

    it "also canonicalizes an empty rule list (`if: []`/`unless: []`) away as no gate" do
      action = build_axn do
        expects :num, type: Integer, if: []
        def call; end
      end
      expect(action.call.ok?).to be false
      expect(action.call(num: 5).ok?).to be true
    end
  end

  # Drift-proof matrix: for the full condition-value matrix, axn's gate decision must AGREE with
  # ActiveModel's own. Both sides are derived from ONE built action — the runtime side by calling it
  # with the gated field ABSENT (an open gate makes `presence` fire; a closed gate lets it through),
  # the axn side by asking the gate oracle on that action's canonicalized validations. No hardcoded
  # expectations that could themselves drift: the assertion is purely that the two AM-derived
  # decisions match, including which values RAISE (String/2-arity/arbitrary #call object) — pinning
  # that axn delegates gating to ActiveModel rather than mirroring it.
  #
  # BOTH gate placements are swept: the declaration-level SHARED gate (`presence: true, if: value`,
  # decided by declaration_gate_open?) AND the per-validator NESTED gate (`presence: { if: value }`,
  # decided by validator_gate_open? on that entry). AM evaluates the nested placement through the
  # same callback machinery, so axn agrees identically for both (Codex round 11).
  describe "axn's gate decision agrees with ActiveModel itself (drift-proof matrix)" do
    condition_matrix = {
      "nil" => nil,
      "false" => false,
      "true" => true,
      "empty String" => "",
      "whitespace String" => " ",
      "[]" => [],
      "[nil]" => [nil],
      "[false]" => [false],
      "Symbol :cond" => :cond,
      "non-blank String" => "names_nothing",
      "proc {}" => proc {},
      "proc {|r|}" => proc { |_r| },
      "proc {|r,*| (arity -2)}" => proc { |_r, *| },
      "proc {|*| (arity -1)}" => proc { |*| },
      "lambda {}" => -> {},
      "lambda {|r|}" => ->(_r) {},
      "->(r,*){} (arity -2 lambda)" => ->(_r, *) {},
      "proc {|a,b| (arity 2)}" => proc { |_a, _b| },
      "object#call" => Class.new { def call(*) = true }.new,
    }.freeze

    # Runtime truth: call the action with `probe_field` absent. Open gate → presence fires
    # (InboundValidationError); closed gate → ok; a raising condition surfaces as a non-validation
    # exception (or escapes .call for a non-StandardError like SystemStackError — caught here).
    def runtime_decision(action)
      result = action.call
      if result.ok?
        :closed
      elsif result.exception.is_a?(Axn::InboundValidationError)
        :open
      else
        [:raised, result.exception.class]
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      [:raised, e.class]
    end

    # axn's decision from the SAME action's canonicalized validations, via the gate oracle. For a
    # nested placement the gate lives inside the `presence:` entry hash, so the oracle is asked about
    # that specific validator entry; for a shared placement there is no nested entry (entry_options
    # nil), which is the declaration_gate_open? special case.
    def axn_decision(action, placement)
      validations = action.internal_field_configs.find { |c| c.field == :probe_field }.validations
      stub = Object.new
      # Symbol :cond resolves against the action, mirrored here
      def stub.cond = true
      open =
        if placement == :nested
          Axn::Validation::Fields.validator_gate_open?(validations:, entry_options: validations[:presence], action: stub)
        else
          Axn::Validation::Fields.declaration_gate_open?(validations:, action: stub)
        end
      open ? :open : :closed
    rescue Exception => e # rubocop:disable Lint/RescueException
      [:raised, e.class]
    end

    %i[if unless].each do |gate|
      %i[shared nested].each do |placement|
        context "gate: #{gate} (#{placement} placement)" do
          condition_matrix.each do |label, value|
            it "matches ActiveModel for #{label}" do
              action = build_axn do
                if placement == :nested
                  expects(:probe_field, presence: { gate => value })
                else
                  expects(:probe_field, presence: true, **{ gate => value })
                end
                def cond = true
                def call; end
              end

              expect(runtime_decision(action)).to eq(axn_decision(action, placement))
            end
          end
        end
      end
    end
  end
end
