# frozen_string_literal: true

RSpec.describe "expects reader alias (as:/prefix:)" do
  describe "top-level `as:`" do
    let(:action) do
      build_axn do
        expects :channel, as: :raw_channel
        exposes :got

        def call
          expose got: raw_channel
        end
      end
    end

    it "reads the inbound wire-key value through the aliased reader" do
      result = action.call(channel: "abc")
      expect(result).to be_ok
      expect(result.got).to eq("abc")
    end

    it "does not define a reader under the wire key (frees the name)" do
      freed = build_axn do
        expects :channel, as: :raw_channel
        exposes :resolved

        def channel = "resolved-#{raw_channel}"
        def call = expose(resolved: channel)
      end

      expect(freed.call(channel: "abc").resolved).to eq("resolved-abc")
    end

    it "keeps the wire key canonical for validation (presence on the wire key)" do
      result = action.call(channel: nil)
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("Channel")
    end

    it "defines the `?` predicate under the aliased name" do
      predicate = build_axn do
        expects :flag, as: :raw_flag, type: :boolean
        exposes :got

        def call = expose(got: raw_flag?)
      end

      expect(predicate.call(flag: true).got).to be(true)
    end
  end

  describe "subfield `as:`" do
    let(:action) do
      build_axn do
        expects :event_params
        expects :id, on: :event_params, as: :event_id
        exposes :got

        def call = expose(got: event_id)
      end
    end

    it "extracts the wire-key subfield under the aliased reader" do
      expect(action.call(event_params: { id: 42 }).got).to eq(42)
    end
  end

  describe "subfield `model:` + `as:`" do
    # Plain (non-ActiveRecord) class with a finder, to keep this runnable outside Rails.
    let(:widget_class) do
      Class.new do
        def self.name = "Widget"
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    let(:action) do
      klass = widget_class
      build_axn do
        expects :payload
        expects :widget, on: :payload, model: { klass:, finder: :find }, as: :event_widget
        exposes :got

        def call = expose(got: event_widget)
      end
    end

    it "resolves the aliased model from the wire-key `_id` in the parent" do
      result = action.call(payload: { widget_id: 7 })
      expect(result).to be_ok
      expect(result.got).to eq(widget_class.new(7))
    end
  end

  describe "`model:` on a subfield reached via a dotted on:" do
    let(:widget_class) do
      Class.new do
        def self.name = "Widget"
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    it "resolves the model from the nested `_id` under the alias" do
      klass = widget_class
      action = build_axn do
        expects :payload, type: Hash
        expects :widget, on: "payload.order", model: { klass:, finder: :find }
        exposes :got

        def call = expose(got: widget)
      end

      result = action.call(payload: { order: { widget_id: 7 } })
      expect(result).to be_ok
      expect(result.got).to eq(widget_class.new(7))
    end

    it "exposes the nested raw id under the `<alias>_id` companion" do
      klass = widget_class
      action = build_axn do
        expects :payload, type: Hash
        expects :widget, on: "payload.order", model: { klass:, finder: :find }
        exposes :got

        def call = expose(got: widget_id)
      end

      expect(action.call(payload: { order: { widget_id: 7 } }).got).to eq(7)
    end

    it "derives a defaulted klass from the field name" do
      stub_const("Widget", widget_class)
      action = build_axn do
        expects :payload, type: Hash
        expects :widget, on: "payload.order", model: { finder: :find }
        exposes :got

        def call = expose(got: widget)
      end

      expect(action.call(payload: { order: { widget_id: 7 } }).got).to eq(widget_class.new(7))
    end
  end

  describe "`model:` subfield reading off a record parent (Extract-backed reads, PRO-2896)" do
    let(:widget_class) do
      Class.new do
        def self.name = "Widget"
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
        def ==(other) = other.is_a?(self.class) && other.id == id
      end
    end

    it "reads the nested `_id` off a record parent via method dispatch (not `[]`)" do
      widget = widget_class
      # A parent record exposing `widget_id` as a METHOD with no `[]` accessor — only Extract's
      # method-dispatch read can reach it (raw `record[:widget_id]` would NoMethodError → nil), so
      # the `:widget` subfield must opt into method dispatch with `method_call: true` (PRO-2898).
      company = Class.new do
        def self.name = "Company"
        def self.find(_id) = new
        def widget_id = 7
      end

      action = build_axn do
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: company, finder: :find }
        expects :widget, on: :company, model: { klass: widget, finder: :find }, method_call: true
        exposes :got

        def call = expose(got: widget)
      end

      result = action.call(payload: { company_id: 1 })
      expect(result).to be_ok
      expect(result.got).to eq(widget_class.new(7))
    end
  end

  describe "`prefix:` (subfield multi-field sugar)" do
    let(:action) do
      build_axn do
        expects :event_params
        expects :id, :type, on: :event_params, prefix: :event_
        exposes :got

        def call = expose(got: "#{event_id}-#{event_type}")
      end
    end

    it "defines one prefixed reader per field" do
      expect(action.call(event_params: { id: 7, type: "x" }).got).to eq("7-x")
    end
  end

  describe "`on:` an aliased parent" do
    it "references the parent by its reader name (the alias)" do
      action = build_axn do
        expects :channel, type: Hash, as: :raw_channel
        expects :sub, on: :raw_channel
        exposes :got

        def call = expose(got: sub)
      end

      expect(action.call(channel: { sub: 42 }).got).to eq(42)
    end

    it "resolves a subfield default through an aliased parent value-level, without writing into the parent" do
      # `on:` references the parent's alias (`raw_channel`); the default resolves the child's value on the
      # read path — it is never written back into the parent (keyed by the wire key `channel`).
      action = build_axn do
        expects :channel, type: Hash, as: :raw_channel
        expects :token, on: :raw_channel, default: "x"
        exposes :got, :parent

        def call = expose(got: token, parent: raw_channel)
      end

      result = action.call(channel: { other: 1 })
      expect(result.got).to eq("x")              # child resolves its default on the read path
      expect(result.parent).to eq({ other: 1 })  # the aliased parent is not mutated with `token`
    end

    it "applies subfield preprocessing through an aliased parent" do
      action = build_axn do
        expects :channel, type: Hash, as: :raw_channel
        expects :token, on: :raw_channel, preprocess: ->(v) { v.to_s.upcase }
        exposes :got

        def call = expose(got: token)
      end

      expect(action.call(channel: { token: "abc" }).got).to eq("ABC")
    end

    it "filters a sensitive subfield declared on an aliased parent" do
      # `config.on` is the parent's reader alias (`raw_channel`), but the inspector keys subfield
      # filtering by the wire key (`channel`) — it must normalize the alias before comparing, or the
      # sensitive value leaks into inspect output.
      action = build_axn do
        expects :channel, type: Hash, as: :raw_channel
        expects :token, on: :raw_channel, sensitive: true
        exposes :internal_ctx

        def call = expose(internal_ctx: internal_context)
      end

      inspected = action.call(channel: { token: "secret123" }).internal_ctx.inspect
      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("secret123")
    end

    it "rejects referencing the parent by its (reader-less) wire key" do
      expect do
        build_axn do
          expects :channel, type: Hash, as: :raw_channel
          expects :sub, on: :channel
        end
      end.to raise_error(ArgumentError, /no such reader|:channel/)
    end

    it "reads (without default) through an aliased subfield parent" do
      # No default/preprocess, so the nested-parent restriction doesn't apply: a subfield `on:` an
      # aliased subfield parent resolves through the reader chain.
      action = build_axn do
        expects :payload
        expects :settings, on: :payload, as: :raw_settings
        expects :enabled, on: :raw_settings
        exposes :got

        def call = expose(got: enabled)
      end

      expect(action.call(payload: { settings: { enabled: true } }).got).to be(true)
    end

    it "resolves a default through an aliased subfield parent value-level, without materializing it (chain-aware read)" do
      # The parent (`raw_settings`) is itself a subfield reached through an alias; the resolved wire path
      # (payload → settings → enabled) drives the read, and the default resolves the child's value without
      # writing the intermediate into the parent.
      action = build_axn do
        expects :payload
        expects :settings, on: :payload, as: :raw_settings, optional: true
        expects :enabled, on: :raw_settings, optional: true, default: true
        exposes :parent, :got, optional: true, allow_nil: true

        def call = expose(parent: payload, got: enabled)
      end

      result = action.call(payload: { other: 1 })
      expect(result.got).to be(true)             # child resolves its default on the read path
      expect(result.parent).to eq({ other: 1 })  # the parent is not materialized with `settings`
    end
  end

  describe "`as:` on a subfield reached via a dotted on:" do
    it "generates a reader under the alias that resolves the nested path" do
      action = build_axn do
        expects :order, type: Hash
        expects :detail, on: "order.items", as: :item_detail
        exposes :got

        def call = expose(got: item_detail)
      end

      expect(action.call(order: { items: { detail: "x" } }).got).to eq("x")
    end

    it "validates the nested value under the aliased reader" do
      action = build_axn do
        expects :order, type: Hash
        expects :qty, on: "order.items", as: :item_qty, type: Integer

        def call = nil
      end

      expect(action.call(order: { items: { qty: 3 } })).to be_ok
      bad = action.call(order: { items: { qty: "nope" } })
      expect(bad.exception).to be_a(Axn::InboundValidationError)
    end

    it "defines the `?` predicate under the aliased name" do
      action = build_axn do
        expects :order, type: Hash
        expects :active, on: "order.flags", type: :boolean
        exposes :got

        def call = expose(got: active?)
      end

      expect(action.call(order: { flags: { active: true } }).got).to be(true)
    end

    it "applies a default for the nested path" do
      action = build_axn do
        expects :order, type: Hash
        expects :tz, on: "order.meta", optional: true, default: "UTC"
        exposes :got

        def call = expose(got: tz)
      end

      expect(action.call(order: { meta: {} }).got).to eq("UTC")
    end

    it "lets a later `on:` anchor on the aliased reader" do
      action = build_axn do
        expects :order, type: Hash
        expects :detail, on: "order.items", type: Hash
        expects :label, on: :detail
        exposes :got

        def call = expose(got: label)
      end

      expect(action.call(order: { items: { detail: { label: "hi" } } }).got).to eq("hi")
    end
  end

  describe "guards" do
    it "rejects `as:` with multiple fields" do
      expect do
        build_axn { expects :a, :b, as: :x }
      end.to raise_error(ArgumentError, /single field/)
    end

    it "rejects `as:` combined with `prefix:`" do
      expect do
        build_axn { expects :id, on: :foo, as: :x, prefix: :p_ }
      end.to raise_error(ArgumentError, /as:.*prefix:|prefix:.*as:/)
    end

    it "rejects a dotted `as:` alias (a reader name can't be dotted)" do
      expect do
        build_axn do
          expects :foo
          expects :zip, on: :foo, as: :"a.b"
        end
      end.to raise_error(ArgumentError, /reader name may not be dotted/)
    end

    it "rejects a dotted top-level field name (the path belongs in on:, not the field name)" do
      expect do
        build_axn { expects "a.b" }
      end.to raise_error(ArgumentError, /dotted field name.*not supported.*on: "a"/m)
    end

    it "rejects a dotted top-level field name even with `as:` (top-level readers aren't path-aware)" do
      expect do
        build_axn { expects "a.b", as: :ab }
      end.to raise_error(ArgumentError, /dotted field name.*not supported/m)
    end

    it "rejects a dotted `exposes` field name (outbound fields have no nested-path reader)" do
      expect do
        build_axn { exposes "a.b" }
      end.to raise_error(ArgumentError, /dotted field name.*not valid for exposes/m)
    end

    it "rejects a dotted subfield field name even WITH on: (dotted names dropped, PRO-2926)" do
      expect do
        build_axn do
          expects :foo
          expects "billing.zip", on: :foo
        end
      end.to raise_error(ArgumentError, /dotted field name/m)
    end

    it "resolves the dotted-`on:` equivalent of a former dotted name" do
      action = build_axn do
        expects :foo, type: Hash
        expects :zip, on: "foo.billing", type: String
        exposes :out
        def call = expose(out: zip)
      end
      result = action.call(foo: { billing: { zip: "90210" } })
      expect(result).to be_ok
      expect(result.out).to eq("90210")
    end

    it "rejects readers: as an unknown key (the kwarg is gone)" do
      expect do
        build_axn do
          expects :foo
          expects :id, on: :foo, readers: false
        end
      end.to raise_error(ArgumentError, /Unknown key\(s\) :readers in field declaration/)
    end

    it "rejects a reserved reader name" do
      expect do
        build_axn { expects :foo, as: :inspect }
      end.to raise_error(Axn::ContractViolation::ReservedAttributeError)
    end

    it "rejects two fields aliased to the same reader" do
      expect do
        build_axn do
          expects :a, as: :shared
          expects :b, as: :shared
        end
      end.to raise_error(ArgumentError, /shared/)
    end

    it "rejects a plain field whose name an earlier alias already claimed" do
      # Reverse order of the alias-vs-alias case: an alias takes `foo`, then a plain `expects :foo`
      # would silently clobber the first field's reader. Caught regardless of declaration order.
      expect do
        build_axn do
          expects :bar, as: :foo
          expects :foo
        end
      end.to raise_error(ArgumentError, /collision/i)
    end

    it "resolves a subfield whose wire key collides with a top-level reader via as: (the rename escape hatch)" do
      # A top-level `id` claims the reader; a subfield with the same wire key renames its reader
      # instead of suppressing it (readers: false is removed), so both values stay accessible.
      action = build_axn do
        expects :id, type: Integer
        expects :org, type: Hash
        expects :id, on: :org, as: :org_id, type: Integer
        exposes :got

        def call = expose(got: [id, org_id])
      end

      expect(action.call(id: 1, org: { id: 2 }).got).to eq([1, 2])
    end
  end
end
