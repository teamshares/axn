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

  it "retains comparison bounds when an unknown type is projected away" do
    action = collision({ type: Object, comparison: { greater_than: 10 } },
                       { type: { klass: Integer, coerce: false } })
    schema = checker(action)
    [1, 10, 11].each do |value|
      expect(schema.valid?(input(value))).to eq(action.call(**input(value)).ok?)
    end
  end

  it "reports post-transform gates separately from unconditional descendant constraints" do
    action = collision({ type: String }, { type: Hash, preprocess: ->(value) { JSON.parse(value) }, length: { minimum: 2, if: -> { false } } }) do
      expects :a, on: "payload.inner", type: String
    end
    residues = []
    Axn::Internal::Reflection::Schema.build_input_for(action, residues:)
    summaries = residues.map(&:last).group_by(&:kind)
    expect(summaries.fetch(:inherent).map(&:summary).join).to include('"properties":{"a":')
    expect(summaries.fetch(:inherent).map(&:summary).join).not_to include('"minProperties":2')
    expect(summaries.fetch(:conditional).map(&:summary).join).to include('"minProperties":2', "after transformation")
    expect(action.call(**input('{"a":"x"}'))).to be_ok
  end

  # Exercise the two routes into conjunction: an explicit subfield and a same-named member
  # reached recursively while merging object properties. Test both operand orders.
  def each_collision_route(member, node, &block)
    [[member, node], [node, member]].each do |left, right|
      nested = build_axn do
        expects(:payload, type: Hash) do
          field(:deep, type: Hash) { field :inner, **left }
        end
        expects(:deep, on: :payload, type: Hash) { field :inner, **right }
        define_method(:call) { nil }
      end
      field_type = right[:type].is_a?(Hash) ? right[:type] : { klass: right[:type] }
      field = right.merge(type: field_type.merge(coerce: false))
      [collision(left, field), nested].each_with_index(&block)
    end
  end

  def nested_input(value, depth)
    payload = { "inner" => value }
    payload = { "deep" => payload } if depth == 1
    { "payload" => payload }
  end

  def verify_size_collisions(member, node, wire_type)
    each_collision_route(member, node) do |action, depth|
      schema = checker(action)
      (1..4).each do |size|
        value = case wire_type.name
                when "String" then "a" * size
                when "Array" then Array.new(size, 1)
                when "Hash" then size.times.to_h { |n| [n.to_s, 1] }
                end
        data = nested_input(value, depth)
        expect(schema.valid?(data)).to eq(action.call(**data).ok?), "depth=#{depth}, value=#{value.inspect}"
      end
    end
  end

  def reported_fragment(residue)
    json = residue.summary.split(" (", 2).last
    json.start_with?("{") ? JSON.parse(json.delete_suffix(")")) : {}
  end

  context "gate and transform composition", :slow do
    [
      [String, { format: { with: /\Aa+\z/ } }, ["", "a", "b", "aaa"]],
      [String, { inclusion: { in: %w[a b] } }, ["", "a", "b", "c"]],
      [Array, { length: { minimum: 2 } }, [[], [1], [1, 2], [1, 2, 3]]],
      [Hash, { length: { minimum: 2 } }, [{}, { "a" => 1 }, { "a" => 1, "b" => 2 }]],
      [Integer, { numericality: { greater_than: 10 } }, [0, 9, 10, 11]],
      [Integer, { comparison: { greater_than: 10 } }, [0, 9, 10, 11]],
    ].each do |type, constraints, values|
      %i[validator declaration].each do |gate_position|
        it "reports #{type} #{constraints.keys} accurately with a #{gate_position} gate" do
          opened = false
          condition = -> { opened }
          declared = if gate_position == :declaration
                       constraints.merge(if: condition)
                     else
                       constraints.transform_values { |options| options.merge(if: condition) }
                     end
          action = collision({ type: String }, declared.merge(type:, preprocess: ->(value) { JSON.parse(value) }))
          residues = []
          Axn::Internal::Reflection::Schema.build_input_for(action, residues:)
          inherent = residues.map(&:last).select { |residue| residue.kind == :inherent }
          conditional = residues.map(&:last).select { |residue| residue.kind == :conditional }
          expect(inherent).not_to be_empty
          expect(conditional).not_to be_empty
          expect(conditional.map(&:summary)).to all(include("after transformation"))

          [false, true].each do |gate_open|
            opened = gate_open
            applied = gate_open ? inherent + conditional : inherent
            post_transform_schema = JSONSchemer.schema({ "allOf" => applied.map { |residue| reported_fragment(residue) } })
            (values + [nil]).each do |value|
              result = action.call(**input(JSON.generate(value)))
              expect(post_transform_schema.valid?(value)).to eq(result.ok?), "gate=#{gate_open}, value=#{value.inspect}"
            end
          end
        end
      end
    end
  end

  context "all numeric-bound producers", :slow do
    schema = Axn::Internal::Reflection::Schema
    # Derive both producer and operator axes from the emitter. A new producer or bound cannot
    # quietly miss this test by being absent from another hand-maintained list of validators.
    schema::NUMERIC_BOUND_ENTRIES.each_key do |validator|
      schema::NUMERIC_BOUND_KEYS.each_key do |operator|
        [Integer, Float, [Integer, Float]].each do |type|
          [false, true].each do |nullable|
            %i[unknown mixed gated].each do |origin|
              it "preserves #{validator}.#{operator} for #{type}, nullable=#{nullable}, #{origin}" do
                source_type = case origin
                              when :unknown then Object
                              when :mixed then [Object, type].flatten
                              when :gated then { klass: String, if: -> { false } }
                              end
                validator_options = { validator => { operator => 10 }, allow_nil: nullable }
                member = validator_options.merge(type: source_type)
                node = { type:, allow_nil: nullable }
                # The equivalent ordinary declaration is a control for projection, while the
                # real runtime remains the authority for acceptance at each boundary value.
                reference = collision(validator_options.merge(type:), node.merge(type: { klass: type, coerce: false }))
                reference_schema = checker(reference)
                values = [0, 9, 10, 11, 20]
                values = values.map(&:to_f) if type == Float
                values += [9.5, 10.5] if type.is_a?(Array)
                values << nil
                each_collision_route(member, node) do |action, depth|
                  emitted = checker(action)
                  values.each do |value|
                    data = nested_input(value, depth)
                    expect(emitted.valid?(data)).to eq(reference_schema.valid?(input(value)))
                    expect(emitted.valid?(data)).to eq(action.call(**data).ok?), "depth=#{depth}, value=#{value.inspect}"
                  end
                end
              end
            end
          end
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
