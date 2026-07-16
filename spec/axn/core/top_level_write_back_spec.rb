# frozen_string_literal: true

RSpec.describe "top-level read-path resolution (PRO-2908)" do
  describe "ContractForSubfields.resolve_value at depth 0" do
    it "resolves a top-level preprocess without mutating provided_data" do
      action = build_axn do
        expects :name, preprocess: lambda(&:strip)
      end
      instance = action.send(:new, name: "  hi  ")
      config = action.internal_field_configs.find { |c| c.field == :name }

      resolved = Axn::Core::ContractForSubfields.resolve_value(instance, config)

      expect(resolved).to eq("hi")
      # provided_data is untouched by the read-path resolution:
      expect(instance.instance_variable_get(:@__context).provided_data[:name]).to eq("  hi  ")
    end

    it "resolves a top-level default when the value is absent" do
      action = build_axn { expects :count, default: 99 }
      instance = action.send(:new)
      config = action.internal_field_configs.find { |c| c.field == :count }

      expect(Axn::Core::ContractForSubfields.resolve_value(instance, config)).to eq(99)
    end
  end

  describe "ContractForSubfields.resolve_model_value at depth 0" do
    it "resolves a top-level model record from a sibling <field>_id default" do
      widget_klass = Class.new do
        def self.all = @all ||= {}
        def self.find(id) = all[id]
        attr_reader :id

        def initialize(id) = (@id = id)
      end
      w = widget_klass.new(7)
      widget_klass.all[7] = w
      stub_const("Widget", widget_klass)

      action = build_axn do
        expects :widget, model: true
        expects :widget_id, default: 7
      end
      instance = action.send(:new) # neither widget nor widget_id supplied

      config = action.internal_field_configs.find { |c| c.field == :widget }
      resolved = Axn::Core::ContractForSubfields.resolve_model_value(instance, config, config.validations[:model])

      expect(resolved).to eq(w)
    end
  end

  describe "no write-back to provided_data (the acceptance wedge)" do
    it "leaves the caller's provided_data byte-for-byte raw while the reader returns transformed" do
      captured = nil
      action = build_axn do
        expects :name, preprocess: lambda(&:strip)
        expects :count, default: 99
        exposes :seen_name, :raw, optional: true
        define_method(:call) do
          captured = @__context.provided_data.dup
          expose(seen_name: name, raw: captured)
        end
      end

      result = action.call(name: "  hi  ")

      expect(result.seen_name).to eq("hi")           # reader → transformed
      expect(result.raw[:name]).to eq("  hi  ")      # provided_data → raw, unmutated
      expect(result.raw).not_to have_key(:count)     # default never materialized into provided_data
    end

    it "does not mutate a caller-supplied settable object referenced by an input" do
      obj = Struct.new(:touched).new(false)
      action = build_axn do
        expects :thing, preprocess: ->(v) { v } # returns same object; must not be mutated in place
      end
      action.call(thing: obj)
      expect(obj.touched).to eq(false)
    end
  end

  describe "#inputs forwards transformed values to a nested action" do
    it "a nested action receiving **inputs sees the parent's coerced/preprocessed/defaulted values" do
      child = build_axn do
        expects :name
        expects :count
        exposes :got, optional: true
        def call = expose(got: [name, count])
      end
      stub_const("ChildAxn", child)

      parent = build_axn do
        expects :name, preprocess: lambda(&:strip)
        expects :count, default: 99
        exposes :child_got, optional: true
        def call = expose(child_got: ChildAxn.call!(**inputs).got)
      end

      expect(parent.call(name: "  hi  ").child_got).to eq(["hi", 99])
    end
  end

  describe "top-level model + declared <field>_id default (present-record authority)" do
    # PORO with a registry-backed finder so `find` returns the SAME instance for a given id
    # (a fresh-per-call finder would mask id-identity assertions).
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, default: 99
        exposes :resolved_company, optional: true

        def call = expose(resolved_company: company)
      end
    end

    before { stub_const("Co", co_class) }

    it "lets a present record win over a defaulted sibling company_id (no fabricated conflict)" do
      record = co_class.new(5) # id 5, DIFFERENT from the company_id default (99)
      co_class.registry[5] = record

      result = action.call(company: record) # NO company_id supplied → default would be 99

      expect(result).to be_ok                       # regression: this raised InboundValidationError
      expect(result.resolved_company).to eq(record) # reader returns the passed record (id 5)
    end

    it "still resolves a record from the defaulted company_id when nothing is supplied" do
      defaulted = co_class.new(99)
      co_class.registry[99] = defaulted

      result = action.call # neither company nor company_id supplied

      expect(result).to be_ok
      expect(result.resolved_company).to eq(defaulted) # resolve_model_via_sibling_id fires at depth 0
    end
  end

  describe "top-level model + caller-supplied <field>_id transform (PRO-2908 codex: preprocess before consistency check)" do
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, preprocess: lambda(&:strip)
        exposes :resolved_company, optional: true

        def call = expose(resolved_company: company)
      end
    end

    before { stub_const("Co", co_class) }

    it "does not fabricate a conflict when the caller-supplied id matches the record only after preprocess:" do
      record = co_class.new(5)
      co_class.registry[5] = record

      result = action.call(company: record, company_id: " 5 ")

      expect(result).to be_ok # regression: this raised InboundValidationError before the fix
      expect(result.resolved_company).to eq(record)
    end

    it "still raises when the caller-supplied id disagrees with the record even after preprocess:" do
      record = co_class.new(5)
      co_class.registry[5] = record

      result = action.call(company: record, company_id: " 6 ")

      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to match(/conflicts with company_id="6"/)
    end
  end

  describe "top-level model + a caller-supplied <field>_id that resolves via its default " \
           "(PRO-2908: model-consistency mirrors the reader, resolving the id at most once)" do
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, default: 99, preprocess: lambda { |v|
          s = v.to_s.strip
          s.empty? ? nil : s
        }
        exposes :resolved_company, optional: true

        def call = expose(resolved_company: company)
      end
    end

    before { stub_const("Co", co_class) }

    it "surfaces the conflict a CALLER-SUPPLIED id resolves to (blank preprocesses to nil → default 99), " \
       "matching what the company_id reader itself returns, rather than diverging from it" do
      record = co_class.new(5)
      co_class.registry[5] = record

      result = action.call(company: record, company_id: "  ")

      # The caller supplied a (blank) company_id; it resolves — via its own default — to 99, which is
      # exactly what the `company_id` reader and validation see. Consistency compares against that same
      # resolved value (never re-running preprocess), so a 99-vs-5 disagreement is reported rather than
      # silently ignored. (A caller who OMITS company_id entirely is exempt — see the next example.)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to match(/conflicts with company_id=99/)
    end

    it "exempts a caller-OMITTED id: the default resolves the record and never fabricates a conflict" do
      defaulted = co_class.new(99)
      co_class.registry[99] = defaulted

      result = action.call # neither company nor company_id supplied → present-record authority N/A, default resolves

      expect(result).to be_ok
      expect(result.resolved_company).to eq(defaulted)
    end
  end

  describe "top-level model + <field>_id coerce: matching an integer-keyed finder record" do
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, type: { klass: Integer, coerce: true }
        exposes :resolved_company, optional: true

        def call = expose(resolved_company: company)
      end
    end

    before { stub_const("Co", co_class) }

    it "coerces the caller-supplied string id before comparing against the present record's integer id" do
      record = co_class.new(5)
      co_class.registry[5] = record

      result = action.call(company: record, company_id: "5")

      expect(result).to be_ok
      expect(result.resolved_company).to eq(record)
    end
  end

  describe "top-level model + transformed <field>_id feeding a STRICT finder (id-only input, PRO-2910)" do
    # A finder that resolves ONLY the exactly-transformed token — so the raw (untransformed) token
    # fails the lookup. This is the case PR #181 regressed: with the top-level write-back pass gone,
    # the record lookup consumed the RAW <field>_id while the reader/validation saw the transformed one.
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        # strict: " 5 " (raw) misses; "5" (stripped) hits
        def self.fetch(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    before { stub_const("Co", co_class) }

    it "resolves the record from a preprocessed id-only input (no record supplied)" do
      co_class.registry["5"] = co_class.new("5")
      action = build_axn do
        expects :company, model: { klass: Co, finder: :fetch }, allow_nil: true
        expects :company_id, preprocess: lambda(&:strip)
        exposes :cid, allow_nil: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: " 5 ") # id ONLY — no company record

      expect(result).to be_ok
      expect(result.cid).to eq("5") # finder consumed the STRIPPED id, not the raw " 5 "
    end

    it "lets a REQUIRED model resolve from a valid preprocessed id-only input (the severe regression)" do
      # Before the fix a *valid* id-only input failed model presence validation: the finder got the
      # raw " 5 " token, returned nil, and a required (non-nil-tolerant) model then rejected the call.
      co_class.registry["5"] = co_class.new("5")
      action = build_axn do
        expects :company, model: { klass: Co, finder: :fetch }
        expects :company_id, preprocess: lambda(&:strip)
        exposes :cid, optional: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: " 5 ")

      expect(result).to be_ok
      expect(result.cid).to eq("5")
    end

    it "still resolves nil when even the TRANSFORMED id fails the lookup (no default to override with)" do
      # A present id that fails its lookup after transform stays nil — there is no sibling default to
      # silently substitute (mirrors the subfield failed-lookup-stays-nil guarantee).
      action = build_axn do
        expects :company, model: { klass: Co, finder: :fetch }, allow_nil: true
        expects :company_id, preprocess: lambda(&:strip)
        exposes :cid, allow_nil: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: " 999 ") # nothing registered under "999"

      expect(result).to be_ok
      expect(result.cid).to be_nil
    end

    it "resolves via a coerced id-only input under coerce_input_types" do
      # The whole-action coercion setting turns the Integer coercion on without a per-field coerce:,
      # and the transformed (coerced) id still feeds the strict finder.
      co_class.registry[5] = co_class.new(5)
      action = build_axn do
        configure { |c| c.coerce_input_types = true }
        expects :company, model: { klass: Co, finder: :fetch }, allow_nil: true
        expects :company_id, type: Integer
        exposes :cid, allow_nil: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: "5") # coerced to Integer 5 before the finder

      expect(result).to be_ok
      expect(result.cid).to eq(5)
    end
  end

  describe "top-level model + a TOLERANT finder consumes the transformed id, not the raw token (PRO-2910)" do
    # A finder that resolves ANY non-blank token (echoing it as the record id). Because the raw lookup would
    # succeed, a raw-first-then-retry approach would silently keep the untransformed token; the lookup must
    # route through the transformed id from the start.
    let(:echo_class) do
      Class.new do
        def self.name = "Echo"
        def self.find(id) = new(id)
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    before { stub_const("Echo", echo_class) }

    it "looks the record up by the preprocessed id even though the raw token would also resolve" do
      action = build_axn do
        expects :company, model: { klass: Echo, finder: :find }, allow_nil: true
        expects :company_id, preprocess: lambda(&:strip)
        exposes :cid, allow_nil: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: " 5 ")

      expect(result).to be_ok
      expect(result.cid).to eq("5") # the finder saw the STRIPPED id, not the raw " 5 " a tolerant find would echo
    end

    it "resolves nil when a present id's preprocess maps it to nil (never re-read raw)" do
      # company_id reader returns nil (preprocessed away); the model must agree — not resolve a record from
      # the raw token a tolerant finder would otherwise accept.
      action = build_axn do
        expects :company, model: { klass: Echo, finder: :find }, allow_nil: true
        expects :company_id, optional: true, preprocess: ->(v) { v == "none" ? nil : v }
        exposes :cid, allow_nil: true
        def call = expose(cid: company&.id)
      end

      result = action.call(company_id: "none")

      expect(result).to be_ok
      expect(result.cid).to be_nil
    end

    it "resolves from the default when a present id preprocesses to nil AND a default is declared (reader parity)" do
      # This is NOT the failed-lookup-stays-nil case (that is a present id resolving to a NON-nil value whose
      # lookup fails). Here the present value transforms to nil, so the field's OWN default: applies — the
      # universal preprocess+default semantic — and the `company_id` reader itself returns 42. The model must
      # resolve from that same 42 (reader/model parity), not diverge to nil.
      action = build_axn do
        expects :company, model: { klass: Echo, finder: :find }, allow_nil: true
        expects :company_id, default: 42, preprocess: ->(v) { v == "none" ? nil : v }
        exposes :cid, allow_nil: true
        exposes :id_reader, allow_nil: true
        def call = expose(cid: company&.id, id_reader: company_id)
      end

      result = action.call(company_id: "none")

      expect(result).to be_ok
      expect(result.id_reader).to eq(42) # the field resolves to its default after preprocess → nil
      expect(result.cid).to eq(42)       # the model agrees with the reader, not nil
    end
  end

  describe "done! raised during outbound copy-forward (PRO-2908 Finding 2)" do
    it "settles rather than escaping .call when a field's read-path default runs first during copy-forward" do
      action = build_axn do
        expects :value, optional: true, default: -> { done!("early from default") }
        exposes :value, optional: true
        # body never reads `value`, so copy-forward is the first read
        def call = nil
      end

      result = action.call

      expect(result).to be_ok
      expect(result.success).to eq("early from default")
    end
  end

  describe "provisional facade memo dropped for a top-level model reader (mechanism-level, PRO-2908 codex finding)" do
    # A top-level `model:` reader memoizes on the InternalContext FACADE singleton (see
    # InternalContext#_define_reader_for), not on the action — a different receiver than a subfield
    # reader. If another field's preprocess reads it mid-resolution (a "provisional" read against an
    # unsettled parent), that facade-side memo must be dropped once the outer field settles, exactly
    # like an action-side subfield reader memo is. A full behavioral staleness repro needs
    # order-dependent id resolution that's impractical to construct reliably, so this asserts the
    # mechanism directly: the facade ivar is gone after settlement.
    let(:widget_klass) do
      Class.new do
        @calls = 0
        class << self
          attr_accessor :calls
        end

        def self.find(id)
          self.calls += 1
          new(id)
        end
        attr_reader :id

        def initialize(id) = (@id = id)
      end
    end

    before { stub_const("Widget", widget_klass) }

    it "does not leave a provisionally-read top-level model reader's facade memo populated after settlement" do
      action = build_axn do
        expects :widget, model: true
        # Reading `widget` here happens WHILE `other`'s own resolve_value is mid-resolution (in_progress
        # non-empty), so the widget reader's facade memo is marked provisional and must be dropped once
        # `other` settles. Driven directly through resolve_value (not the full inbound pipeline), so the
        # ONLY read of `widget` is this provisional one — `widget`'s own field validation never runs
        # independently to re-populate the memo afterward, which would mask the bug either way.
        expects :other, preprocess: ->(v) { v.tap { widget } }
      end
      instance = action.send(:new, widget_id: 1, other: "x")
      other_config = action.internal_field_configs.find { |c| c.field == :other }

      resolved = Axn::Core::ContractForSubfields.resolve_value(instance, other_config)

      expect(resolved).to eq("x")
      facade = instance.internal_context
      expect(facade.instance_variable_defined?(:@_memoized_reader_widget)).to be(false)
    end

    it "still memoizes a normal (non-provisional) top-level model read (finder called once)" do
      action = build_axn do
        expects :widget, model: true
      end
      instance = action.send(:new, widget_id: 1)

      first = instance.widget
      second = instance.widget

      expect(first).to equal(second)
      expect(widget_klass.calls).to eq(1)
    end

    it "does not leave a provisionally-read ALIASED top-level model reader's facade memo populated " \
       "after settlement (the facade memoizes under the WIRE field name, not the reader alias)" do
      action = build_axn do
        expects :widget, as: :thing, model: true
        # Reading the ALIAS `thing` here happens WHILE `other`'s own resolve_value is mid-resolution,
        # so the provisional-memo mechanism must record the facade's ACTUAL memo ivar
        # (@_memoized_reader_widget, keyed by the wire field), not one derived from the alias
        # (@_memoized_reader_thing, which the facade never sets).
        expects :other, preprocess: ->(v) { v.tap { thing } }
      end
      instance = action.send(:new, widget_id: 1, other: "x")
      other_config = action.internal_field_configs.find { |c| c.field == :other }

      resolved = Axn::Core::ContractForSubfields.resolve_value(instance, other_config)

      expect(resolved).to eq("x")
      facade = instance.internal_context
      expect(facade.instance_variable_defined?(:@_memoized_reader_widget)).to be(false)
    end
  end

  describe "model default: reading its own model reader (self-referential default, PRO-2908 codex finding)" do
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    before { stub_const("Co", co_class) }

    it "resolves the fallback record instead of recursing to SystemStackError when default: reads " \
       "the SAME model reader it defaults (default: -> { company || fallback })" do
      klass = co_class
      fallback = co_class.new(:fallback)
      action = build_axn do
        expects :company, model: { klass:, finder: :find }, default: -> { company || fallback }
        exposes :resolved_company, optional: true

        define_method(:call) { expose(resolved_company: company) }
      end

      result = action.call # neither company nor company_id supplied

      expect(result).to be_ok
      expect(result.resolved_company).to eq(fallback)
    end

    it "still resolves a NON-self-referential model default: (regression guard)" do
      klass = co_class
      fallback = co_class.new(:fallback2)
      action = build_axn do
        expects :company, model: { klass:, finder: :find }, default: -> { fallback }
        exposes :resolved_company, optional: true

        define_method(:call) { expose(resolved_company: company) }
      end

      result = action.call # neither company nor company_id supplied

      expect(result).to be_ok
      expect(result.resolved_company).to eq(fallback)
    end
  end

  describe "model + sibling <field>_id default reading the SAME model reader (PRO-2908 codex P1)" do
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    before { stub_const("Co", co_class) }

    it "resolves via the sibling-id fallback instead of recursing to SystemStackError when the sibling " \
       "company_id default reads the SAME company model reader (default: -> { company&.id || 99 })" do
      klass = co_class
      record99 = co_class.new(99)
      co_class.registry[99] = record99
      action = build_axn do
        expects :company, model: { klass:, finder: :find }
        expects :company_id, default: -> { company&.id || 99 }
        exposes :resolved_company, optional: true

        define_method(:call) { expose(resolved_company: company) }
      end

      result = action.call # neither company nor company_id supplied

      expect(result).to be_ok
      expect(result.resolved_company).to eq(record99)
    end
  end

  describe "model default: reading a SUBFIELD of itself leaves no stale provisional memo (PRO-2908 codex P2)" do
    let(:acct_class) do
      Class.new do
        def self.name = "Acct"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id, :owner

        def initialize(id, owner: nil)
          @id = id
          @owner = owner
        end
      end
    end

    before { stub_const("Acct", acct_class) }

    it "re-resolves `owner` against the SETTLED account rather than returning the nil memoized while the " \
       "model `account` default (which reads owner, then supplies a fallback account) was mid-flight" do
      klass = acct_class
      settled = acct_class.new(7, owner: "real-owner")
      acct_class.registry[7] = settled
      action = build_axn do
        expects :account, model: { klass:, finder: :find }, default: -> { owner.then { Acct.find(7) } }
        expects :owner, on: :account, method_call: true
      end
      instance = action.send(:new) # no account / account_id supplied

      instance.account # settles account via default; reads owner provisionally mid-resolution

      # The provisional `owner` memo (nil, taken while `account` was still resolving) must be dropped once
      # `account` settles, so this read re-resolves against the settled account instead of the stale nil.
      expect(instance.owner).to eq("real-owner")
    end
  end

  describe "exception-report inputs show RAW caller input" do
    it "reports the raw invocation arg for a field with a declared transform" do
      captured = nil
      Axn.config.on_exception = ->(context:) { captured = context[:inputs] }
      action = build_axn do
        expects :name, preprocess: lambda(&:strip)
        def call = raise "boom"
      end
      action.call(name: "  hi  ")
      expect(captured[:name]).to eq("  hi  ")
    ensure
      Axn.config.on_exception = nil
    end

    it "still redacts a sensitive: top-level field in the raw report (filtering keys off the name)" do
      captured = nil
      Axn.config.on_exception = ->(context:) { captured = context[:inputs] }
      action = build_axn do
        expects :token, sensitive: true, preprocess: lambda(&:strip)
        def call = raise "boom"
      end
      action.call(token: "  secret  ")
      expect(captured[:token]).to eq("[FILTERED]")
    ensure
      Axn.config.on_exception = nil
    end
  end

  describe "generated <field>_id companion agrees with a declared, transformed id field (PRO-2908 codex P2)" do
    # A model's `<field>_id` key is ALSO declared as a top-level field with an alias + a transform.
    # The auto-generated `company_id` companion reader must reflect that field's transformed value —
    # not the raw wire token — so it agrees with the declared field's own reader and validation.
    let(:co_class) do
      Class.new do
        def self.name = "Co"
        def self.registry = @registry ||= {}
        def self.find(id) = registry[id]
        attr_reader :id

        def initialize(id) = (@id = id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    let(:action) do
      klass = co_class
      build_axn do
        expects :company, model: { klass:, finder: :find }, allow_nil: true
        expects :company_id, as: :co_id, preprocess: ->(v) { v.to_s.strip }
        exposes :via_alias, :via_companion, allow_nil: true
        def call = expose(via_alias: co_id, via_companion: company_id)
      end
    end

    before { stub_const("Co", co_class) }

    it "routes the companion through the declared id field's transform (companion == alias, both normalized)" do
      co_class.registry["5"] = co_class.new("5")

      result = action.call(company_id: "  5  ")

      expect(result).to be_ok
      expect(result.via_alias).to eq("5")     # the declared field's own reader (aliased)
      expect(result.via_companion).to eq("5") # the model's generated <field>_id companion — same normalized value
    end
  end
end
