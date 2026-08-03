# frozen_string_literal: true

# `type: :params` exists for Rails, so the emptiness axis has to hold for the value Rails actually hands
# a controller: an `ActionController::Parameters`, which answers `empty?` but reports no size. Needs real
# Parameters, so it lives here rather than in the non-Rails suite.
RSpec.describe "allow_empty: on type: :params" do
  def build(**opts)
    action = build_axn do
      expects :payload, **opts
    end
    action.define_method(:call) { nil }
    action
  end

  describe "allow_empty: false" do
    subject(:action) { build(type: :params, allow_empty: false) }

    it "rejects an empty Parameters" do
      result = action.call(payload: ActionController::Parameters.new({}))
      expect(result).not_to be_ok
      expect(result.exception.message).to include("can't be empty")
    end

    it "rejects an empty Hash" do
      result = action.call(payload: {})
      expect(result).not_to be_ok
      expect(result.exception.message).to include("can't be empty")
    end

    it "accepts a non-empty Parameters" do
      expect(action.call(payload: ActionController::Parameters.new(name: "Alice"))).to be_ok
    end

    it "accepts a non-empty Hash" do
      expect(action.call(payload: { name: "Alice" })).to be_ok
    end

    it "rejects nil, which no tolerance was declared for" do
      expect(action.call(payload: nil)).not_to be_ok
    end

    it "reaches the empty Parameters through a nil-tolerance too" do
      tolerant = build(type: :params, optional: true, allow_empty: false)
      expect(tolerant.call(payload: nil)).to be_ok
      expect(tolerant.call(payload: ActionController::Parameters.new({}))).not_to be_ok
      expect(tolerant.call(payload: ActionController::Parameters.new(name: "Alice"))).to be_ok
    end

    it "advertises the floor the runtime enforces" do
      expect(action.input_schema[:properties][:payload]).to eq(type: "object", minProperties: 1)
    end
  end

  describe "allow_empty: true" do
    subject(:action) { build(type: :params, allow_empty: true) }

    it "accepts an empty Parameters" do
      expect(action.call(payload: ActionController::Parameters.new({}))).to be_ok
    end

    it "accepts an empty Hash" do
      expect(action.call(payload: {})).to be_ok
    end

    it "still rejects nil" do
      expect(action.call(payload: nil)).not_to be_ok
    end
  end
end

# An omitted call resolves the default, so a default the field's own checks reject makes the key
# un-omittable. The emptiness check asks the value `empty?`, which an `ActionController::Parameters`
# answers — so reflection has to recognize it as an empty container the same way it recognizes a Hash.
RSpec.describe "an empty ActionController::Parameters default" do
  def action_for(**opts)
    klass = Class.new do
      include Axn
      def call = nil
    end
    klass.expects :payload, **opts
    klass
  end

  it "requires the key when the emptiness check rejects the default" do
    action = action_for(type: :params, allow_empty: false, default: ActionController::Parameters.new)

    expect(action.call).not_to be_ok # the omitted call resolves the default and fails
    expect(Array(action.input_schema[:required])).to include("payload")
  end

  it "requires the key when an explicit presence check rejects the default" do
    action = action_for(type: :params, presence: true, default: ActionController::Parameters.new)

    expect(action.call).not_to be_ok
    expect(Array(action.input_schema[:required])).to include("payload")
  end

  it "keeps the key omittable for a non-empty Parameters default" do
    action = action_for(type: :params, allow_empty: false, default: ActionController::Parameters.new(name: "Alice"))

    expect(action.call).to be_ok
    expect(Array(action.input_schema[:required])).not_to include("payload")
  end

  it "already requires the key for the plain Hash spelling" do
    action = action_for(type: :params, allow_empty: false, default: {})

    expect(action.call).not_to be_ok
    expect(Array(action.input_schema[:required])).to include("payload")
  end
end
