# frozen_string_literal: true

RSpec.describe "_model_fields cache" do
  let(:co_class) do
    Class.new do
      def self.name = "Co"
      attr_reader :id

      def initialize(id) = @id = id
      def self.find(id) = new(id)
    end
  end

  it "returns the same Hash object across calls when the contract hasn't changed" do
    klass = co_class
    action = build_axn { expects :company, model: { klass:, finder: :find } }

    first = action._model_fields
    second = action._model_fields

    expect(first).to equal(second)
  end

  it "rebuilds after the class redeclares the field, with the same content" do
    klass = co_class
    action = build_axn { expects :company, model: { klass:, finder: :find } }
    first = action._model_fields

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._model_fields

    expect(second).not_to equal(first)
    expect(second).to eq(first)
  end

  it "gives a subclass its own cache rather than inheriting the parent's cached Hash" do
    klass = co_class
    parent = build_axn { expects :company, model: { klass:, finder: :find } }
    child = Class.new(parent)

    expect(child._model_fields).not_to equal(parent._model_fields)
    expect(child._model_fields).to eq(parent._model_fields)
  end

  it "returns a frozen Hash, since it's a public class method any caller could hold onto and mutate" do
    klass = co_class
    action = build_axn { expects :company, model: { klass:, finder: :find } }

    expect(action._model_fields).to be_frozen
  end

  it "still resolves a model field's reader correctly through the facade" do
    klass = co_class
    action = build_axn do
      expects :company, model: { klass:, finder: :find }
      exposes :co_id
      def call = expose(co_id: company.id)
    end

    result = action.call(company_id: 7)

    expect(result.co_id).to eq(7)
  end
end
