# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "json_schemer"
require "json"
require "date"
require "bigdecimal"

# The declarations the precision-only refusals used to turn away, generated as a product over the axes those refusals
# read rather than listed one by one — type form (single, union, nullable, union+nullable, Data, a class JSON has no
# type for), access (plain key vs `method_call:`), position (field, dotted intermediate, block member, raw member,
# `of:` bag, map axis, model id), requiredness (required, optional, literal and Proc defaults), gate (none, closed,
# open), a value-replacing `preprocess:`, and each guard's own options (`container:`, `id_type:`, the tolerance, the
# inclusion set's shape). Every cell that declares is held to both inbound directions against a pool of ordinary
# values: never reject what the runtime accepts, and name everything accepted that the runtime rejects.
#
# Why a product: each review finding on these relaxations was the same defect — a removed refusal let a declaration
# reach an emitter site written on the assumption it never would, so the site read it too narrowly (a union's types,
# an explicit `container:`, a `method_call:` claim). Instances found one at a time say nothing about their neighbours;
# the product asks every neighbour. It is small enough to run whole (about 5,800 cells), so it is not reduced.
module RelaxedRefusalProduct
  class Rec
    def self.fetch(id) = new(id)
    def initialize(id) = @id = id
  end
  Point = Data.define(:x)
  Money = Class.new

  def self.member(field, method_call: false, **validations)
    Axn::Core::Contract::ShapeConfig.new(field:, validations:, method_call:)
  end

  SKU = member(:sku, type: { klass: String })

  Cell = Data.define(:group, :id, :decl, :path, :array)

  # Ordinary values first — an id, an email, a date string, a count, blanks, small arrays and hashes — then the
  # type-boundary probes the positions need (a member-bearing element, a nested Array).
  POOL = [nil, "", " ", "a", "abc123", "user@example.com", "2020-01-01", 1, 42, 0, 3.5, true, false,
          [], [1], [1, 2], ["a"], [""], [[]], {}, { "a" => 1 }, { "sku" => "A1" }, { "sku" => 5 },
          [{ "sku" => "A1" }], [{ "sku" => 5 }], [{}], ["abc"], [[{ "sku" => 1 }]], { "detail" => "x" }, { "detail" => 5 }].freeze
  OMITTED = Object.new.freeze
  SCALAR_ID_TYPES = %w[Integer String :uuid Float Date BigDecimal Time Symbol].freeze

  P = "RelaxedRefusalProduct"
  TYPES = { "String" => "String", "Integer" => "Integer", "Array" => "Array", "Hash" => "Hash",
            "[Array,String]" => "[Array, String]", "[Array,NilClass]" => "[Array, NilClass]",
            "[Array,String,NilClass]" => "[Array, String, NilClass]", "Data" => "#{P}::Point", "unknown" => "#{P}::Money",
            "[String,Integer]" => "[String, Integer]", "[String,NilClass]" => "[String, NilClass]" }.freeze
  GATES = { "ungated" => "", "closed" => ", if: -> { false }", "open" => ", if: -> { true }" }.freeze
  MODEL = "model: { klass: #{P}::Rec, finder: :fetch".freeze

  module_function

  # Every combination of the named axes, each an ordered `{label => value}`, yielded as `[labels, values]`.
  def combos(axes)
    names = axes.keys
    axes.values.map(&:to_a).reduce([[]]) { |acc, axis| acc.product(axis).map { |prefix, pair| prefix + [pair] } }.each do |pairs|
      yield names.zip(pairs.map(&:first)).to_h, names.zip(pairs.map(&:last)).to_h
    end
  end

  def cells
    @cells ||= model_claim_cells + inclusion_cells + raw_shape_cells + id_type_cells + length_floor_cells +
               union_of_cells + presence_cells
  end

  def cell(group, id, decl, path, array: false) = Cell.new(group:, id: "#{group}|#{id}", decl:, path:, array:)

  # A `model:` field's generated id, claimed by a nested declaration reading a plain key or a method off it.
  def model_claim_cells
    axes = { type: %w[String Integer [String,Integer] [String,NilClass] Data].to_h { |t| [t, TYPES[t]] },
             access: { "plain" => ["detail", ""], "method_call" => ["size", ", method_call: true"] },
             req: { "required" => "", "optional" => ", optional: true", "default" => :literal, "procdefault" => :proc },
             gate: GATES, pre: { "none" => "", "replacing" => ', preprocess: ->(v) { v.nil? ? v : "fixed" }' },
             model: { "required" => "", "optional" => ", optional: true" } }
    out = []
    combos(axes) do |l, v|
      next if l[:pre] == "replacing" && l[:type] != "String"

      req = claim_requiredness(l[:type], v[:req])
      next if req.nil?

      out.concat(model_claim_spellings(l, v, req))
    end
    out
  end

  def claim_requiredness(type_name, req)
    literal = { "String" => '"x"', "Integer" => "1", "[String,Integer]" => '"x"', "[String,NilClass]" => '"x"' }[type_name]
    case req
    when :literal then literal && ", default: #{literal}"
    when :proc then literal && ", default: -> { #{literal} }"
    else req
    end
  end

  def model_claim_spellings(labels, values, req)
    leaf, access = values[:access]
    model = "expects :company, on: :payload, #{MODEL} }#{values[:model]}"
    opts = "type: #{values[:type]}#{access}#{req}#{values[:gate]}#{values[:pre]}"
    id = labels.values.join(" ")
    path = %i[payload company_id]
    out = [
      cell("G1", "dotted #{id}", "expects :payload, type: Hash\n#{model}\nexpects :#{leaf}, on: \"payload.company_id\", #{opts}", path),
      cell("G1", "sibling #{id}", "expects :payload, type: Hash\n#{model}\nexpects :company_id, on: :payload, as: :cid, type: Hash" \
                                  "#{values[:gate]}\nexpects :#{leaf}, on: :cid, #{opts}", path),
    ]
    return out unless labels[:pre] == "none" && %w[required optional].include?(labels[:req])

    raw_leaf = "#{P}.member(:#{leaf}, method_call: #{labels[:access] == 'method_call'}, type: { klass: #{values[:type]} }" \
               "#{labels[:req] == 'optional' ? ', allow_blank: true' : ''})"
    out << cell("G1", "block member #{id}", "expects :payload, type: Hash do\n field :company_id, type: Hash#{values[:gate]} do\n  " \
                                            "field :#{leaf}, type: #{values[:type]}#{access}#{req}\n end\nend\n#{model}", path)
    out << cell("G1", "raw member #{id}", "expects :payload, type: Hash, shape: { members: [#{P}.member(:company_id, type: { klass: Hash }" \
                                          "#{values[:gate]}, shape: { members: [#{raw_leaf}] })] }\n#{model}", path)
  end

  # An `inclusion:` set a tolerated blank rescues, at a field, an `of:` bag and a block member.
  def inclusion_cells
    axes = { set: { "wrong [1]" => "[1]", "right-str" => '["a"]', "right-arr" => "[[1]]", "mixed" => '["a", 1]', "range" => "1..3" },
             type: %w[Array String Hash [Array,String] [Array,NilClass] [Array,String,NilClass] Data unknown].to_h { |t| [t, TYPES[t]] },
             tol: { "entry allow_blank" => [", allow_blank: true", ""], "decl allow_blank" => ["", ", allow_blank: true"],
                    "optional" => ["", ", optional: true"], "entry allow_nil" => [", allow_nil: true", ""] },
             presence: { "default" => "", "presence false" => ", presence: false" },
             gate: { "ungated" => ["", ""], "entry closed" => [", if: -> { false }", ""], "decl open" => ["", ", if: -> { true }"] } }
    out = []
    combos(axes) do |l, v|
      inc = "inclusion: { in: #{v[:set]}#{v[:tol][0]}#{v[:gate][0]} }"
      rest = "#{v[:tol][1]}#{v[:presence]}#{v[:gate][1]}"
      id = l.values.join(" ")
      out << cell("G4", "field #{id}", "expects :val, type: #{v[:type]}, #{inc}#{rest}", %i[val])
      out << cell("G4", "bag #{id}", "expects :val, type: Array, of: { klass: #{v[:type]}, #{inc}#{rest} }", %i[val], array: true)
      out << cell("G4", "member #{id}", "expects :o, type: Hash do\n field :val, type: #{v[:type]}, #{inc}#{rest}\nend", %i[o val])
    end
    out
  end

  # A raw `shape:` beside each type, with and without a hand-written `container:`, at every position one is written.
  def raw_shape_cells
    axes = { type: { "Array" => "Array", "Hash" => "Hash", "none" => nil, "Data" => "#{P}::Point", "[Array,Hash]" => "[Array, Hash]" },
             container: { "cArray" => "Array", "cHash" => "Hash", "c-" => nil, "cData" => "#{P}::Point" },
             req: { "req" => "", "optional" => ", optional: true" }, gate: { "ungated" => "", "closed" => ", if: -> { false }" },
             of: { "no of" => "", "of Hash" => ", of: Hash", "of String" => ", of: String" } }
    out = []
    combos(axes) do |l, v|
      shape = v[:container] ? "{ container: #{v[:container]}, members: [#{P}::SKU] }" : "{ members: [#{P}::SKU] }"
      type = v[:type] ? "type: #{v[:type]}, " : ""
      id = l.values.join(" ")
      out << cell("G5", "field #{id}", "expects :val, #{type}shape: #{shape}#{v[:of]}#{v[:req]}#{v[:gate]}", %i[val])
      out << cell("G5", "member #{id}", "expects :o, type: Hash do\n field :val, #{type}shape: #{shape}#{v[:of]}#{v[:req]}#{v[:gate]}\nend", %i[o val])
      raw_type = v[:type] ? "type: { klass: #{v[:type]} }, " : ""
      raw_tol = l[:req] == "optional" ? ", allow_blank: true" : ""
      out << cell("G5", "raw member #{id}", "expects :o, type: Hash, shape: { members: [#{P}.member(:val, #{raw_type}shape: #{shape}" \
                                            "#{v[:of]}#{raw_tol}#{v[:gate]})] }", %i[o val])
      next unless l[:of] == "no of"

      klass = v[:type] ? "klass: #{v[:type]}, " : ""
      out << cell("G5", "bag #{id}", "expects :val, type: Array#{v[:req]}, of: { #{klass}shape: #{shape}#{v[:gate]} }", %i[val], array: true)
    end
    out
  end

  # `id_type:` naming any class, beside each explicit `<field>_id` sibling, at the top level and nested.
  def id_type_cells
    axes = { id_type: %w[Integer String :uuid Float Date Hash Array Object TrueClass BigDecimal Time Symbol].to_h { |t| [t, t] }
                                                                                                            .merge("unknown" => "#{P}::Money"),
             sibling: { "none" => nil, "String" => "type: String", "Integer" => "type: Integer", "[Integer,String]" => "type: [Integer, String]",
                        "NilClass opt" => "type: NilClass, optional: true", "untyped default" => "default: 5" },
             pos: { "top" => :top, "nested" => :nested }, model: { "required" => "", "optional" => ", optional: true" },
             gate: { "ungated" => "", "closed" => ", if: -> { false }" } }
    out = []
    combos(axes) do |l, v|
      model = "#{MODEL}, id_type: #{v[:id_type]} }#{v[:model]}#{v[:gate]}"
      id = "#{l[:id_type]} sib:#{l[:sibling]} #{l[:pos]} #{l[:model]} #{l[:gate]}"
      if v[:pos] == :top
        decl = "expects :company, #{model}#{"\nexpects :company_id, #{v[:sibling]}" if v[:sibling]}"
        out << cell("G7", id, decl, %i[company_id])
      else
        decl = "expects :payload, type: Hash\nexpects :company, on: :payload, #{model}" \
               "#{"\nexpects :company_id, on: :payload, as: :pcid, #{v[:sibling]}" if v[:sibling]}"
        out << cell("G7", id, decl, %i[payload company_id])
      end
    end
    out
  end

  # `allow_empty: false` beside a `length:` floor resolved per call.
  def length_floor_cells
    axes = { type: %w[String Array Hash [String,NilClass]].to_h { |t| [t, TYPES[t]] }, floor: { "proc" => "->(_r) { 2 }", "symbol" => ":floor" },
             tol: { "none" => "", "allow_nil" => ", allow_nil: true", "allow_blank" => ", allow_blank: true", "optional" => ", optional: true" },
             gate: { "ungated" => "", "closed" => ", if: -> { false }" } }
    out = []
    combos(axes) do |l, v|
      body = "type: #{v[:type]}, allow_empty: false, length: { minimum: #{v[:floor]} }#{v[:tol]}#{v[:gate]}"
      id = l.values.join(" ")
      out << cell("G8", "field #{id}", "def floor = 2\nexpects :val, #{body}", %i[val])
      out << cell("G8", "member #{id}", "def floor = 2\nexpects :o, type: Hash do\n field :val, #{body}\nend", %i[o val])
    end
    out
  end

  # `of:` on a union, with an element type, a bag, a shape block and a nested container.
  def union_of_cells
    axes = { type: { "[Array,String]" => "[Array, String]", "[Array,NilClass]" => "[Array, NilClass]", "[Array,:boolean]" => "[Array, :boolean]",
                     "[Array,Integer,NilClass]" => "[Array, Integer, NilClass]", "[Array,Hash]" => "[Array, Hash]",
                     "[Hash,String]" => "[Hash, String]", "Array" => "Array" },
             of: { "Integer" => "of: Integer", "format bag" => 'of: { klass: String, format: { with: /\A[a-z]+\z/ } }',
                   "shape block" => :block, "nested" => "of: { klass: Array, of: Integer }" },
             req: { "required" => "", "optional" => ", optional: true", "default" => ", default: []" },
             gate: { "ungated" => "", "closed" => ", if: -> { false }" } }
    out = []
    combos(axes) do |l, v|
      id = l.values.join(" ")
      if v[:of] == :block
        next out << cell("G9", "field #{id}", "expects(:val, type: #{v[:type]}, of: Hash#{v[:req]}#{v[:gate]}) { field :sku, type: String }",
                         %i[val])
      end

      out << cell("G9", "field #{id}", "expects :val, type: #{v[:type]}, #{v[:of]}#{v[:req]}#{v[:gate]}", %i[val])
      unless l[:req] == "default"
        out << cell("G9", "member #{id}", "expects :o, type: Hash do\n field :val, type: #{v[:type]}, #{v[:of]}#{v[:req]}#{v[:gate]}\nend",
                    %i[o val])
      end
      if l[:req] == "required" && l[:gate] == "ungated"
        out << cell("G9", "bag #{id}", "expects :val, type: Array, of: { klass: #{v[:type]}, #{v[:of]} }", %i[val],
                    array: true)
      end
    end
    out
  end

  # A tolerance beside an explicit `presence:`, at every position the two can meet.
  def presence_cells
    axes = { type: %w[String Array Hash Integer [String,NilClass]].to_h { |t| [t, TYPES[t]] },
             tol: { "allow_nil" => "allow_nil: true", "allow_blank" => "allow_blank: true", "optional" => "optional: true" },
             presence: { "true" => "presence: true", "allow_nil false" => "presence: { allow_nil: false }",
                         "allow_blank false" => "presence: { allow_blank: false }", "gated closed" => "presence: { if: -> { false } }" } }
    out = []
    combos(axes) do |l, v|
      id = l.values.join(" ")
      pair = "#{v[:tol]}, #{v[:presence]}"
      raw_pair = "#{v[:tol].sub('optional: true', 'allow_blank: true')}, #{v[:presence]}"
      out << cell("G10", "field #{id}", "expects :val, type: #{v[:type]}, #{pair}", %i[val])
      out << cell("G10", "field transformed #{id}", "expects :val, type: #{v[:type]}, #{pair}, preprocess: ->(v) { v }", %i[val])
      out << cell("G10", "member #{id}", "expects :o, type: Hash do\n field :val, type: #{v[:type]}, #{pair}\nend", %i[o val])
      out << cell("G10", "raw member #{id}", "expects :o, type: Hash, shape: { members: [#{P}.member(:val, type: { klass: #{v[:type]} }, #{raw_pair})] }",
                  %i[o val])
      out << cell("G10", "bag #{id}", "expects :val, type: Array, of: { klass: #{v[:type]}, #{pair} }", %i[val], array: true)
      out << cell("G10", "map #{id}", "expects :val, type: Hash, of: { values: { klass: #{v[:type]}, #{pair} } }", %i[val])
    end
    out
  end
end

RSpec.describe "the declarations the precision-only refusals used to refuse, against runtime truth", :slow do
  def schemer(schema) = JSONSchemer.schema(JSON.parse(JSON.generate(schema)), regexp_resolver: "ecma")

  def declare(decl)
    Class.new do
      include Axn
      class_eval(decl)
      def call = nil
    end
  rescue ArgumentError
    nil
  end

  def payload_for(cell, value)
    return {} if RelaxedRefusalProduct::OMITTED.equal?(value) && cell.path.size == 1

    inner = if RelaxedRefusalProduct::OMITTED.equal?(value)
              {}
            else
              { cell.path.last => (cell.array ? [value] : value) }
            end
    cell.path[0...-1].reverse.reduce(inner) { |acc, key| { key => acc } }
  end

  # The stated exceptions of the doctrine (AGENTS.md, "exact at its core"), each asked as narrowly as the payload
  # allows so a regression beside one still fails.
  def stated_exception?(cell, value, direction, satisfiable:)
    return true if direction == :looser && value == " " # a String presence's whitespace
    return false unless direction == :stricter
    return true if value.nil? && cell.id.include?("default") # an explicit nil a `default:` fills
    # The model id's narrower type: a scalar `id_type:` states a type the lookup never checks.
    return true if cell.group == "G7" && !value.nil? && RelaxedRefusalProduct::SCALAR_ID_TYPES.include?(cell.id.split("|").last.split.first)

    # A blank-tolerant position's skipped blank, which the emitted `enum`/members still refuse (PRO-3244) — only where
    # the node is otherwise satisfiable: a node that admits no non-blank value is not that exception but a set or
    # shape no value can meet, which is exactly what a relaxed refusal must not leave behind.
    satisfiable && cell.id.match?(/allow_blank|optional/) && non_nil_blank?(value)
  end

  def non_nil_blank?(value)
    !value.nil? && (value == false || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?))
  end

  # Divergences these declarations share with code that predates the relaxation, deferred to PRO-3582 by name.
  def deferred?(cell)
    # A hand-written `container:` the declared type does not imply: none declared, a union, or a Data container beside
    # `type: Hash`.
    if cell.group == "G5" && (match = cell.id.match(/\|(?:raw member|field|member|bag) (\S+) (\S+) /))
      type, container = match.captures
      return true if %w[cHash cData].include?(container) && %w[none [Array,Hash]].include?(type)
      return true if type == "Hash" && container == "cData"
    end

    # A required `model:` beside a null-only explicit `<field>_id`, which no wire call can satisfy.
    cell.group == "G7" && cell.id.include?("sib:NilClass opt") && cell.id.include?(" required ")
  end

  it "never rejects a value the runtime accepts, and names every value it accepts that the runtime rejects" do
    stricter = []
    unreported = []
    declared = 0

    RelaxedRefusalProduct.cells.each do |cell|
      klass = declare(cell.decl)
      next if klass.nil? || deferred?(cell)

      declared += 1
      document = schemer(klass.input_schema)
      reported = klass.input_schema_residues.any?
      verdicts = (RelaxedRefusalProduct::POOL + [RelaxedRefusalProduct::OMITTED]).map do |value|
        payload = payload_for(cell, value)
        [value, payload, klass.call(**payload).ok?, document.valid?(JSON.parse(JSON.generate(payload)))]
      end
      satisfiable = verdicts.any? do |value, _payload, _runtime_ok, document_ok|
        document_ok && !RelaxedRefusalProduct::OMITTED.equal?(value) && !non_nil_blank?(value)
      end
      verdicts.each do |value, payload, runtime_ok, document_ok|
        stricter << "#{cell.id}: runtime accepts #{payload.inspect}" if runtime_ok && !document_ok && !stated_exception?(cell, value, :stricter, satisfiable:)
        next unless document_ok && !runtime_ok && !reported && !stated_exception?(cell, value, :looser, satisfiable:)

        unreported << "#{cell.id}: document accepts #{payload.inspect} unreported"
      end
    end

    expect(RelaxedRefusalProduct.cells.size).to be > 5_000
    expect(declared).to be > 4_000
    expect(stricter).to be_empty, "stricter than the runtime:\n  #{stricter.first(40).join("\n  ")}"
    expect(unreported).to be_empty, "looser and unreported:\n  #{unreported.first(40).join("\n  ")}"
  end
end
