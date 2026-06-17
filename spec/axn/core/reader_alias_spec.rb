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

    it "rejects referencing the parent by its (reader-less) wire key" do
      expect do
        build_axn do
          expects :channel, type: Hash, as: :raw_channel
          expects :sub, on: :channel
        end
      end.to raise_error(ArgumentError, /no such reader|:channel/)
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

    it "rejects an alias when readers: false" do
      expect do
        build_axn do
          expects :foo
          expects :id, on: :foo, as: :x, readers: false
        end
      end.to raise_error(ArgumentError, /readers: false/)
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
  end
end
