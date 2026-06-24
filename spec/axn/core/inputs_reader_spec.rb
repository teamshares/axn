# frozen_string_literal: true

RSpec.describe "#inputs reader" do
  it "returns declared inbound fields with resolved defaults" do
    action = build_axn do
      expects :a
      expects :b, default: 99
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1, b: 99)
  end

  it "applies preprocessing to the returned values" do
    action = build_axn do
      expects :a, preprocess: ->(v) { v * 10 }
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 2).captured).to eq(a: 20)
  end

  it "forwards a preprocess result for an omitted optional, but omits one that resolves to nil" do
    # apply_inbound_preprocessing! runs preprocess on the omitted field's nil and writes the result
    # back into provided_data. A non-nil result (here "") is a real resolved value the reader sees,
    # so it forwards; a nil result must NOT forward as `field: nil` (it would clobber a child's default).
    action = build_axn do
      expects :role, optional: true, preprocess: ->(v) { v.to_s.strip } # nil -> ""
      expects :note, optional: true, preprocess: ->(v) { v&.strip }     # nil -> nil
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call.captured).to eq(role: "")
  end

  it "forwards a boolean false value (non-nil, not falsy-filtered)" do
    action = build_axn do
      expects :flag, optional: true
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(flag: false).captured).to eq(flag: false)
  end

  it "excludes undeclared passthrough keys" do
    action = build_axn do
      expects :a
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1, z: 99).captured).to eq(a: 1)
  end

  it "omits absent optional fields" do
    action = build_axn do
      expects :a
      expects :b, optional: true
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1)
  end

  it "round-trips through a child call via splat" do
    child = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      def call = expose(sum: a + b)
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      define_method(:call) { expose(c.call(**inputs)) }
    end

    expect(parent.call(a: 2, b: 3).sum).to eq(5)
  end

  it "supports subsetting and override with Hash methods" do
    child = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      def call = expose(pair: [a, b])
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      define_method(:call) { expose(c.call(**inputs.except(:b), b: 0)) }
    end

    expect(parent.call(a: 1, b: 9).pair).to eq([1, 0])
  end

  # Model-backed inputs: the resolved record only ever lives inside the reader — provided_data
  # holds the record (when passed directly) or only the `<field>_id` (when passed by id). `inputs`
  # must forward the resolved record under the wire key in both cases, or a same-contract child
  # would receive nothing and fail validation.
  describe "model-backed inputs" do
    let(:klass) do
      Class.new do
        attr_reader :id

        def initialize(id) = @id = id
        def self.find(id) = new(id)
      end
    end

    it "forwards the resolved record when provided by id" do
      k = klass
      action = build_axn do
        expects :company, model: { klass: k, finder: :find }
        exposes :captured, optional: true
        def call = expose(captured: inputs)
      end

      captured = action.call(company_id: 5).captured
      expect(captured.keys).to eq([:company])
      expect(captured[:company].id).to eq(5)
    end

    it "forwards the record when provided directly" do
      k = klass
      record = klass.new(7)
      action = build_axn do
        expects :company, model: { klass: k, finder: :find }
        exposes :captured, optional: true
        def call = expose(captured: inputs)
      end

      expect(action.call(company: record).captured).to eq(company: record)
    end

    it "round-trips a by-id model input through a same-contract child" do
      k = klass
      child = build_axn do
        expects :company, model: { klass: k, finder: :find }
        exposes :company_id_seen, optional: true
        def call = expose(company_id_seen: company.id)
      end
      c = child
      parent = build_axn do
        expects :company, model: { klass: k, finder: :find }
        exposes :company_id_seen, optional: true
        define_method(:call) { expose(c.call(**inputs)) }
      end

      expect(parent.call(company_id: 5).company_id_seen).to eq(5)
    end

    it "omits an absent optional model field" do
      k = klass
      action = build_axn do
        expects :company, model: { klass: k, finder: :find }, optional: true
        exposes :captured, optional: true
        def call = expose(captured: inputs)
      end

      expect(action.call.captured).to eq({})
    end
  end
end
