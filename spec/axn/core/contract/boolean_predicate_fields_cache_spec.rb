# frozen_string_literal: true

RSpec.describe "_boolean_predicate_fields cache" do
  it "returns the same Array object across calls" do
    action = build_axn { exposes :approved, type: :boolean }

    expect(action._boolean_predicate_fields).to equal(action._boolean_predicate_fields)
  end

  it "pairs each boolean field with its `<field>?` predicate name" do
    action = build_axn do
      exposes :approved, type: :boolean
      exposes :name
    end

    expect(action._boolean_predicate_fields).to eq([%i[approved? approved]])
  end

  it "skips a boolean field already spelled with a `?`" do
    action = build_axn { exposes :approved?, type: :boolean }

    expect(action._boolean_predicate_fields).to be_empty
  end

  it "rebuilds (new object, same content) after redeclaration" do
    action = build_axn { exposes :approved, type: :boolean }
    first = action._boolean_predicate_fields

    action.external_field_configs = action.external_field_configs.dup.freeze
    second = action._boolean_predicate_fields

    expect(second).not_to equal(first)
    expect(second).to eq(first)
  end

  it "gives a subclass its own cache rather than inheriting the parent's cached Array" do
    parent = build_axn { exposes :approved, type: :boolean }
    child = Class.new(parent)

    expect(child._boolean_predicate_fields).not_to equal(parent._boolean_predicate_fields)
    expect(child._boolean_predicate_fields).to eq(parent._boolean_predicate_fields)
  end

  it "returns a frozen Array" do
    action = build_axn { exposes :approved, type: :boolean }

    expect(action._boolean_predicate_fields).to be_frozen
  end

  it "still resolves a boolean predicate correctly through the Result facade" do
    action = build_axn do
      exposes :approved, type: :boolean
      def call = expose(approved: true)
    end

    result = action.call

    expect(result.approved).to be(true)
    expect(result.approved?).to be(true)
  end
end
