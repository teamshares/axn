# frozen_string_literal: true

RSpec.describe "_internal_field_index cache" do
  it "returns the same Hash object across calls" do
    action = build_axn { expects :name }

    expect(action._internal_field_index).to equal(action._internal_field_index)
  end

  it "maps each internal field to its own config" do
    action = build_axn do
      expects :name
      expects :age, type: Integer
    end

    index = action._internal_field_index
    expect(index.keys).to contain_exactly(:name, :age)
    expect(index[:age].field).to eq(:age)
  end

  it "rebuilds (new object, same content) after redeclaration" do
    action = build_axn { expects :name }
    first = action._internal_field_index

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._internal_field_index

    expect(second).not_to equal(first)
    expect(second.keys).to eq(first.keys)
  end

  it "gives a subclass its own cache rather than inheriting the parent's cached Hash" do
    parent = build_axn { expects :name }
    child = Class.new(parent)

    expect(child._internal_field_index).not_to equal(parent._internal_field_index)
    expect(child._internal_field_index.keys).to eq(parent._internal_field_index.keys)
  end

  it "returns a frozen Hash" do
    action = build_axn { expects :name }

    expect(action._internal_field_index).to be_frozen
  end

  # `internal_field_configs.find { |c| c.field == field }` returned the FIRST match; a plain
  # `each_with_object` build would keep the LAST instead, silently changing which config a duplicated
  # field resolves through for a config array assigned directly (the DSL's own `_reject_duplicate_fields!`
  # keeps `expects` itself from ever producing this shape).
  it "keeps the FIRST config for a duplicated field, matching Array#find" do
    action = build_axn { expects :name }
    first_config = action.internal_field_configs.first
    second_config = Axn::Core::Contract::FieldConfig.new(field: :name, validations: { presence: true }, reader_as: :name)
    action.internal_field_configs = [first_config, second_config].freeze

    expect(action.internal_field_configs.find { |c| c.field == :name }).to equal(first_config)
    expect(action._internal_field_index[:name]).to equal(first_config)
  end

  it "still resolves a field's reader correctly through the facade" do
    action = build_axn do
      expects :name
      exposes :greeting
      def call = expose(greeting: "hi #{name}")
    end

    expect(action.call(name: "world").greeting).to eq("hi world")
  end
end
