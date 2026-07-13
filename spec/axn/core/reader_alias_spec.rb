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

    it "applies a subfield default into the wire-key parent (not the alias)" do
      # The default-mutation path writes into provided_data, which is keyed by the wire key
      # (`channel`), even though `on:` references the parent's alias (`raw_channel`).
      action = build_axn do
        expects :channel, type: Hash, as: :raw_channel
        expects :token, on: :raw_channel, default: "x"
        exposes :got

        def call = expose(got: token)
      end

      expect(action.call(channel: {}).got).to eq("x")
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

    it "applies a default on a subfield declared `on:` an aliased subfield parent (chain-aware write)" do
      # The parent (`raw_settings`) is itself a subfield reached through an alias; the resolved wire
      # path (payload → settings → enabled) drives the nested write.
      action = build_axn do
        expects :payload
        expects :settings, on: :payload, as: :raw_settings, optional: true
        expects :enabled, on: :raw_settings, optional: true, default: true
        exposes :parent, optional: true

        def call = expose(parent: payload)
      end

      expect(action.call(payload: { other: 1 }).parent).to eq({ other: 1, settings: { enabled: true } })
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

    it "rejects aliasing a dotted subfield key" do
      expect do
        build_axn do
          expects :foo
          expects "billing.zip", on: :foo, as: :zip
        end
      end.to raise_error(ArgumentError, /dotted/)
    end

    it "rejects readers: false (removed) with a pointer at as:/prefix:" do
      expect do
        build_axn do
          expects :foo
          expects :id, on: :foo, readers: false
        end
      end.to raise_error(ArgumentError, /`readers: false` has been removed/)
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

    it "lets a later alias claim a dotted subfield's leaf name (no reader generated)" do
      # A dotted subfield key generates no reader, so its leaf name stays free for a later alias
      # to claim — it must not register a phantom collision.
      action = build_axn do
        expects :payload
        expects "meta.id", on: :payload, optional: true, type: Integer
        expects :raw_id, as: :id
        exposes :got

        def call = expose(got: id)
      end

      expect(action.call(payload: { meta: { id: 1 } }, raw_id: 99).got).to eq(99)
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
