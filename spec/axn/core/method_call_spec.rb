# frozen_string_literal: true

# `method_call: true` opts a subfield into the sharp path — resolving a segment by INVOKING it as a
# method (Array methods, PORO readers, Data behavioral methods). Without it, the safe default reads
# declared data only, and reaching a method-dispatch segment raises loudly (PRO-2898).
RSpec.describe "expects ..., method_call: true" do
  # The canonical os-app shape: a plain object exposing `data` via an attr_reader (no dig/[]).
  let(:event_class) do
    Class.new do
      attr_reader :data

      def initialize(data) = (@data = data)
    end
  end

  describe "declaration guard" do
    it "rejects method_call: true on a top-level (non-subfield) declaration" do
      expect do
        build_axn { expects :name, method_call: true }
      end.to raise_error(ArgumentError, /method_call:.*only.*subfield|subfield.*method_call:/i)
    end

    it "allows method_call: false on a top-level declaration (a no-op, not an error)" do
      expect { build_axn { expects :name, method_call: false } }.not_to raise_error
    end
  end

  describe "composing with default: (value-level, PRO-2889)" do
    # A subfield default is resolved on the read path (PRO-2889 value-level defaults), so it composes
    # with method_call: the method is invoked, and its nil result falls back to the default.
    it "falls back to the default when the invoked method returns nil" do
      event_class = Class.new do
        attr_reader :data

        def initialize(data) = (@data = data)
      end
      action = build_axn do
        expects :event
        expects :data, on: :event, method_call: true, default: "fallback"
        exposes :out
        def call = expose(out: data)
      end
      expect(action.call(event: event_class.new(nil)).out).to eq("fallback")
      expect(action.call(event: event_class.new("present")).out).to eq("present")
    end
  end

  describe "resolving a PORO reader subfield (event.data)" do
    let(:action) do
      build_axn do
        expects :event
        expects :data, on: :event, method_call: true
        exposes :out

        def call
          expose out: data
        end
      end
    end

    it "resolves the reader and validates" do
      result = action.call(event: event_class.new({ x: 1 }))
      expect(result).to be_ok
      expect(result.out).to eq({ x: 1 })
    end
  end

  describe "resolving an Array-method subfield (items.count)" do
    let(:action) do
      build_axn do
        expects :payload
        expects "items.count", on: :payload, as: :item_count, type: Integer, method_call: true
        exposes :out

        def call
          expose out: item_count
        end
      end
    end

    it "resolves the derived value" do
      result = action.call(payload: { items: [10, 20, 30] })
      expect(result).to be_ok
      expect(result.out).to eq(3)
    end
  end

  describe "with coerce_input_types enabled globally" do
    # coerce_input_types auto-coerces every coercible-typed field by writing back into provided_data
    # before validation. For a method_call subfield the read honors the opt-in (no gate crash) but the
    # write-back can't reach the method-derived value, so coercion is a no-op and it validates as-is.
    before { Axn.config.coerce_input_types = true }
    after { Axn.config.coerce_input_types = false }

    it "resolves a coercible-typed method_call subfield without crashing" do
      action = build_axn do
        expects :payload
        expects "items.count", on: :payload, as: :item_count, type: Integer, method_call: true
        exposes :out
        def call = expose(out: item_count)
      end
      result = action.call(payload: { items: [10, 20, 30] })
      expect(result).to be_ok
      expect(result.out).to eq(3)
    end
  end

  describe "a subfield nested UNDER a method_call parent" do
    # The pre-validation passes and stranded-path diagnostic walk the wire path off the raw inbound
    # arguments; when an intermediate hop is a method_call subfield, that walk must honor the
    # intermediate's own opt-in (per the design's generic-hop rule) rather than crash. This is the
    # canonical os-app shape: `:data on :event` (method dispatch) with a subfield read off `:data`.
    let(:event_class_returning) do
      ->(data) { Class.new { define_method(:data) { data } }.new }
    end

    it "reports the real validation failure (not the gate error) when a nested leaf is absent" do
      Axn.config.instance_variable_set(:@on_exception, nil)
      action = build_axn do
        expects :event
        expects :data, on: :event, method_call: true # event.data -> Hash
        expects :name, on: :data, type: String, presence: true # data[:name] (safe key read)
        exposes :out, allow_nil: true
        def call = expose(out: name)
      end

      result = action.call(event: event_class_returning.call({ other: "x" }))
      expect(result).not_to be_ok
      # The failure is an ordinary inbound validation error about the missing leaf — NOT the sharp-read
      # gate error crashing the stranded-path diagnostic. (The detail rides on the dev-facing #message.)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to match(/name/i)
    end

    it "resolves a nested leaf through the method_call parent when present" do
      action = build_axn do
        expects :event
        expects :data, on: :event, method_call: true
        expects :name, on: :data, type: String
        exposes :out
        def call = expose(out: name)
      end
      result = action.call(event: event_class_returning.call({ name: "Ada" }))
      expect(result).to be_ok
      expect(result.out).to eq("Ada")
    end

    it "resolves a defaulted leaf's value-level default through the method_call parent (PRO-2889)" do
      # The parent is method-dispatched (event.data → Hash); the leaf's default resolves on the read
      # path, so a missing key falls back to the default without any write-back into the object.
      action = build_axn do
        expects :event
        expects :data, on: :event, method_call: true
        expects :role, on: :data, type: String, default: "member"
        exposes :out
        def call = expose(out: role)
      end
      expect(action.call(event: event_class_returning.call({ other: "x" })).out).to eq("member")
      expect(action.call(event: event_class_returning.call({ role: "admin" })).out).to eq("admin")
    end

    it "does not crash coerce_input_types for a coercible subfield under a method_call parent" do
      # coerce_input_types walks the wire chain across the method_call parent honoring its opt-in, so
      # the read doesn't raise the gate error; the coerced write-back can't reach a method-derived
      # parent, so it's a no-op and the value validates as declared.
      Axn.config.coerce_input_types = true
      action = build_axn do
        expects :event
        expects :data, on: :event, method_call: true
        expects :n, on: :data, type: Integer
        exposes :out
        def call = expose(out: n)
      end
      result = action.call(event: event_class_returning.call({ n: 3 }))
      expect(result).to be_ok
      expect(result.out).to eq(3)
    ensure
      Axn.config.coerce_input_types = false
    end
  end

  describe "a readerless dotted method_call ancestor crossed by another subfield" do
    # A dotted-name method_call subfield generates no reader, so a deeper subfield's `on:` chain
    # crosses it as a raw hop in resolve_parent. That hop must honor the ancestor's opt-in (its config
    # carries method_call: true) rather than raise the gate error.
    it "resolves through the opted-in dotted ancestor rather than raising" do
      event_obj = Class.new { def data = { name: "Ada" } }.new
      action = build_axn do
        expects :payload, type: Hash
        expects "event.data", on: :payload, method_call: true # dotted name, no as: -> no reader
        expects :name, on: "payload.event.data", type: String
        exposes :out, allow_nil: true
        def call = expose(out: name)
      end
      result = action.call(payload: { event: event_obj })
      expect(result).to be_ok
      expect(result.out).to eq("Ada")
    end
  end

  describe "reader-vs-dotted parity with method_call: true (PR #162)" do
    it "resolves identically whether spelled `on:`-reader or dotted-name" do
      via_reader = build_axn do
        expects :items
        expects :count, on: :items, as: :count_via_reader, method_call: true
        exposes :out
        def call = expose(out: count_via_reader)
      end
      via_dotted = build_axn do
        expects :payload
        expects "items.count", on: :payload, as: :count_via_dotted, method_call: true
        exposes :out
        def call = expose(out: count_via_dotted)
      end

      expect(via_reader.call(items: [1, 2, 3]).out).to eq(3)
      expect(via_dotted.call(payload: { items: [1, 2, 3] }).out).to eq(3)
    end
  end

  describe "loud failure when the flag is omitted" do
    let(:original_handler) { Axn.config.instance_variable_get(:@on_exception) }
    before { Axn.config.instance_variable_set(:@on_exception, nil) }
    after { Axn.config.instance_variable_set(:@on_exception, original_handler) }

    let(:action) do
      build_axn do
        expects :event
        expects :data, on: :event # NO method_call: — reaching event.data must raise loudly
        exposes :out

        def call
          expose out: data
        end
      end
    end

    it "is not ok" do
      expect(action.call(event: event_class.new({ x: 1 }))).not_to be_ok
    end

    it "surfaces the generic headline on result.error (not the raw message)" do
      result = action.call(event: event_class.new({ x: 1 }))
      expect(result.error).to eq("Something went wrong")
    end

    it "fires the global on_exception (a bug), not on_failure" do
      captured = nil
      Axn.config.instance_variable_set(:@on_exception, ->(e, **) { captured = e })
      action.call(event: event_class.new({ x: 1 }))
      expect(captured).to be_a(Axn::ContractViolation::MethodCallNotPermittedError)
      expect(captured.message).to include("method_call: true")
    end

    it "is not swallowed by the model resolver's finder rescue (custom-finder model subfield)" do
      # A model subfield resolves the record via its reader; the resolver's derive_value has a broad
      # `rescue StandardError` around the finder that also covers the `_id` read. A custom finder isn't
      # id-based, so the model-consistency check doesn't run — leaving derive_value the only reader. The
      # gate error must still propagate loudly rather than be swallowed to nil (→ a misleading presence
      # failure). PRO-2898 explicitly requires no intermediate rescue swallows the distinct error.
      loan_klass = Class.new do
        def self.name = "Loan"
        def self.lookup(id) = new(id)
        def initialize(id) = (@id = id)
        attr_reader :id
      end
      event_with_id = Class.new { def loan_id = 42 }.new # exposes loan_id method, not loan

      captured = nil
      Axn.config.instance_variable_set(:@on_exception, ->(e, **) { captured = e })
      action = build_axn do
        expects :event
        expects :loan, on: :event, model: { klass: loan_klass, finder: :lookup } # NO method_call:
        exposes(:out, allow_nil: true)
        def call = expose(out: loan)
      end

      result = action.call(event: event_with_id)
      expect(result).not_to be_ok
      expect(captured).to be_a(Axn::ContractViolation::MethodCallNotPermittedError)
    end

    it "does not fire on_failure" do
      fired = false
      klass = build_axn do
        expects :event
        expects :data, on: :event
        on_failure { fired = true }
        def call = data
      end
      klass.call(event: event_class.new({ x: 1 }))
      expect(fired).to be(false)
    end
  end
end
