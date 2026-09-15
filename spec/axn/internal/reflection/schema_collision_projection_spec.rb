# frozen_string_literal: true

require "spec_helper"
require "json_schemer"

RSpec.describe "collision projection ownership" do
  def collision(member, node, &children)
    build_axn do
      expects(:payload, type: Hash) { field :inner, **member }
      expects :inner, on: :payload, **node
      class_eval(&children) if children
      define_method(:call) { nil }
    end
  end

  def checker(action)
    JSONSchemer.schema(JSON.parse(JSON.generate(action.input_schema)))
  end

  def input(value) = { "payload" => { "inner" => value } }

  it "retains the bounds of each conditional union branch" do
    action = collision({ type: { klass: [Array, String], if: -> { false } }, length: { minimum: 2 } },
                       { type: { klass: Array, coerce: false } })
    schema = checker(action)
    expect(action.call(**input([1]))).not_to be_ok
    expect(schema.valid?(input([1]))).to be(false)
    expect(action.call(**input([1, 2]))).to be_ok
    expect(schema.valid?(input([1, 2]))).to be(true)
  end

  it "retains real bounds beside an unknown type token" do
    action = collision({ type: [Object, Hash], length: { minimum: 2 } }, { type: Hash })
    schema = checker(action)
    expect(action.call(**input({ "a" => 1 }))).not_to be_ok
    expect(schema.valid?(input({ "a" => 1 }))).to be(false)
    expect(action.call(**input({ "a" => 1, "b" => 2 }))).to be_ok
    expect(schema.valid?(input({ "a" => 1, "b" => 2 }))).to be(true)
  end

  it "reports only the conditional pattern when another pattern runs unconditionally" do
    action = collision({ type: String, numericality: { only_integer: true }, format: { with: /\A[0-9]+\z/, if: -> { false } } },
                       { type: String })
    prop = action.input_schema.dig(:properties, :payload, :properties, :inner)
    expect(prop[:description]).to include('"pattern":"^[0-9]+$"')
    expect(prop[:description]).not_to include("d+$")
    expect(checker(action).valid?(input("+12"))).to be(true)
    expect(action.call(**input("+12"))).to be_ok
  end

  it "keeps a transformed subtree with the value its checks judge" do
    action = collision({ type: String }, { type: Hash, preprocess: ->(value) { JSON.parse(value) } }) do
      expects :a, on: "payload.inner", type: String
    end
    prop = action.input_schema.dig(:properties, :payload, :properties, :inner)
    expect(prop[:type]).to eq("string")
    expect(prop).not_to have_key(:properties)
    expect(prop[:description]).to include('"properties":{"a":')
    value = input('{"a":"x"}')
    expect(action.call(**value)).to be_ok
    expect(checker(action).valid?(value)).to be(true)
    expect(checker(action).valid?(input({ "a" => "x" }))).to be(false)
  end

  it "does not read caller state as its warning memo" do
    action = collision({ type: String }, { type: Integer })
    action.instance_variable_set(:@_axn_residue_warnings, true)
    expect { action.input_schema }.not_to raise_error
    expect(action.instance_variable_get(:@_axn_residue_warnings)).to be(true)
  end

  it "retains an earlier conjunction when three object routes contribute enums" do
    action = build_axn do
      expects(:payload, type: Hash) do
        field(:deep, type: Hash) { field :inner, type: Hash, inclusion: { in: [{ a: 1 }, { b: 2 }] } }
      end
      expects(:deep, on: :payload, type: Hash) do
        field :inner, type: Hash, inclusion: { in: [{ b: 2 }, { c: 3 }] }
      end
      expects :inner, on: "payload.deep", type: Hash, inclusion: { in: [{ b: 2 }, { c: 3 }] }
      def call = nil
    end
    schema = checker(action)
    [{ b: 2 }, { c: 3 }].each do |inner|
      value = { payload: { deep: { inner: } } }
      expect(schema.valid?(JSON.parse(JSON.generate(value)))).to eq(action.call(**value).ok?)
    end
  end

  it "keeps descendants in a transformed branch even when that branch has gated validators" do
    action = collision({ type: String }, { type: Hash, preprocess: ->(value) { JSON.parse(value) }, length: { minimum: 2, if: -> { false } } }) do
      expects :a, on: "payload.inner", type: String
    end
    prop = action.input_schema.dig(:properties, :payload, :properties, :inner)
    expect(prop[:description]).to include('"properties":{"a":')
    expect(prop).to include(type: "string")
    expect(checker(action).valid?(input('{"a":"x"}'))).to be(true)
    expect(action.call(**input('{"a":"x"}'))).to be_ok
  end

  it "retains an unconditional absence ceiling when the type is gated" do
    action = collision({ type: { klass: [Array, String], if: -> { false } }, presence: false, absence: true },
                       { type: { klass: Array, coerce: false }, presence: false })
    schema = checker(action)
    [[], [1]].each do |value|
      expect(schema.valid?(input(value))).to eq(action.call(**input(value)).ok?)
    end
  end

  it "does not infer a numeric-only type for an unconditional numeric-string validator" do
    action = collision({ type: { klass: [Array, String], if: -> { false } }, numericality: { only_integer: true } },
                       { type: String })
    schema = checker(action)
    ["12", "+12", "abc"].each do |value|
      expect(schema.valid?(input(value))).to eq(action.call(**input(value)).ok?)
    end
  end

  it "retains presence when an approximate type meets a nullable boolean in either order" do
    [[{ type: Object }, { type: { klass: :boolean, coerce: false }, optional: true }],
     [{ type: :boolean, optional: true }, { type: Object }]].each do |member, node|
      action = collision(member, node)
      schema = checker(action)
      [true, false, nil].each do |value|
        expect(schema.valid?(input(value))).to eq(action.call(**input(value)).ok?)
      end
    end
  end

  # Exercise the two routes into conjunction: an explicit subfield and a same-named member
  # reached recursively while merging object properties. Test both operand orders.
  def verify_size_collisions(member, node, wire_type)
    [[member, node], [node, member]].each do |left, right|
      nested = build_axn do
        expects(:payload, type: Hash) do
          field(:deep, type: Hash) { field :inner, **left }
        end
        expects(:deep, on: :payload, type: Hash) { field :inner, **right }
        define_method(:call) { nil }
      end
      [collision(left, right), nested].each_with_index do |action, depth|
        schema = checker(action)
        (1..4).each do |size|
          value = case wire_type.name
                  when "String" then "a" * size
                  when "Array" then Array.new(size, 1)
                  when "Hash" then size.times.to_h { |n| [n.to_s, 1] }
                  end
          payload = { "inner" => value }
          payload = { "deep" => payload } if depth == 1
          data = { "payload" => payload }
          expect(schema.valid?(data)).to eq(action.call(**data).ok?), "depth=#{depth}, value=#{value.inspect}"
        end
      end
    end
  end

  context "across colliding declarations", :slow do
    [String, Array, Hash].each do |wire_type|
      [{ minimum: 2 }, { maximum: 2 }, { is: 2 }, { in: 2..3 }].each do |length|
        [Object, [Class.new, wire_type], [Object, wire_type], [Object, String, wire_type]].each do |unknown|
          it "enforces #{wire_type} #{length} beside an approximate type #{unknown}" do
            verify_size_collisions({ type: unknown, length: }, { type: wire_type }, wire_type)
          end
        end
        [[wire_type], [Array, String], [Hash, Array, String], [TrueClass, wire_type]].each do |types|
          it "enforces #{wire_type} #{length} when #{types} is gated" do
            verify_size_collisions({ type: { klass: types, if: -> { false } }, length: }, { type: wire_type }, wire_type)
          end
        end
      end
    end
  end
end
