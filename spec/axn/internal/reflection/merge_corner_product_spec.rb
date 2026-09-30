# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "json_schemer"
require "json"

# Several declarations meeting at one wire node, generated as a product rather than listed. Every route kind that
# can land on a node — an explicit field (reached by a dotted `on:` or through an `as:` alias of its anchor), a
# dotted child that makes the node an intermediate (read by key or by `method_call:`), a block shape member, a raw
# shape member, a `model:` route's generated id, a `model:` route's own raw key, a `Data`-inferred member
# placeholder, and a map's `of:` values axis — is paired with every other, and each route varies its type
# (Hash, String, untyped, the `[Hash, String]` union) and its presence (required, optional, `allow_nil`, a literal
# and a Proc default, a closed and an open gate, a value-preserving `preprocess:`). Every cell that declares is held to both inbound directions
# against a pool of ordinary values at that node: never reject what the runtime accepts, and name everything
# accepted that the runtime rejects with a residue on the path the payload actually reaches.
#
# The reduction, so the product runs in tens of seconds: declaration order varies only where both routes are
# configs of the node itself (the explicit and `model:` kinds) — a shape member, a map axis and a placeholder are
# part of the anchor's own declaration, and a dotted child is a config of a child node. Measured by re-declaring
# every such cell with its route lines reversed: the only differences are a `description`'s wording and the order
# of a `required` list, never what the document accepts. Two explicit routes are generated as an ORDERED product
# of their variations, which already declares each content pair in both orders. A triple is generated for the
# three routes that meet at one node most often in real contracts, over a smaller set of variations. A variation
# declaration refuses by design is not generated: a block member's `default:`, and a map axis naming no class.
#
# Why a product: several declarations meeting at one node is one class of defect with one shape — an emitter site
# reading the node from ONE of its routes (the representative explicit route, a member's forced object type, a
# child's requiredness without asking how it reads) — and instances found one at a time say nothing about their
# neighbours.
module MergeCornerProduct
  class Rec
    def self.fetch(id) = id.nil? ? nil : new
  end
  Point = Data.define(:company, :company_id, :other)

  def self.member(field, **validations)
    Axn::Core::Contract::ShapeConfig.new(field:, validations:, method_call: false)
  end

  P = "MergeCornerProduct"
  MODEL = "model: { klass: #{P}::Rec, finder: :fetch }".freeze
  OMITTED = Object.new.freeze
  ROOT = %i[payload inner].freeze

  # Ordinary values first — blanks, a word, an email, numbers, a flag, small arrays and hashes — then the object
  # values a dotted child reads into.
  POOL = [OMITTED, nil, "", "a", "user@example.com", 1, 0, true, [], [1], {}, { "a" => 1 },
          { "leaf" => "a" }, { "leaf" => 5 }, { "leaf" => nil }].freeze

  TYPES = { "Hash" => ["type: Hash", "Hash"], "String" => ["type: String", "String"], "untyped" => ["", nil],
            "union" => ["type: [Hash, String]", "[Hash, String]"] }.freeze
  LITERALS = { "Hash" => '{ "a" => 1 }', "String" => '"x"', "untyped" => '"x"', "union" => '"x"' }.freeze
  PRESENCES = { "required" => "", "optional" => "optional: true", "allow_nil" => "allow_nil: true",
                "default" => :literal, "procdefault" => :proc, "closed" => "if: -> { false }", "open" => "if: -> { true }",
                "transformed" => "preprocess: ->(v) { v }" }.freeze

  # A route is one declaration landing on the node: `lines` are whole declarations of their own, `member` a block
  # member of the anchor, `raw` a raw member of the anchor's `shape:`, `anchor` options of the anchor itself.
  Route = Data.define(:kind, :label, :lines, :member, :raw, :anchor, :node, :base)
  Cell = Data.define(:pair, :id, :decl, :path, :base, :routes)

  module_function

  def presence(label, type_label)
    value = PRESENCES.fetch(label)
    case value
    when :literal then "default: #{LITERALS.fetch(type_label)}"
    when :proc then "default: -> { #{LITERALS.fetch(type_label)} }"
    else value
    end
  end

  def opts(*parts) = parts.reject { |p| p.nil? || p.empty? }.join(", ")

  def route(kind, label, node: :company, base: {}, lines: [], member: nil, raw: nil, anchor: nil)
    Route.new(kind:, label: "#{kind}(#{label})", lines:, member:, raw:, anchor:, node:, base:)
  end

  def value_variations(types = TYPES.keys - ["union"], presences = PRESENCES.keys)
    types.product(presences) + [%w[union required], %w[union optional]]
  end

  # An explicit field, reached by a dotted `on:` (`E`) or through the anchor's `as:` alias (`A`).
  def explicit_routes(spelling, node: :company, variations: value_variations)
    variations.map do |type, pres|
      on = spelling == "A" ? "on: :pin" : 'on: "payload.inner"'
      line = "expects :#{node}, #{opts(on, "as: :r_#{spelling.downcase}", TYPES[type][0], presence(pres, type))}"
      route(spelling, "#{type} #{pres}", node:, lines: [line])
    end
  end

  # A dotted child under the node, read by key or by `method_call:`, which makes the node an intermediate.
  def dotted_routes(node: :company, presences: PRESENCES.keys, on: "\"payload.inner.#{node}\"")
    %w[key method].product(presences).map do |access, pres|
      child = if access == "key"
                opts("expects :leaf", "on: #{on}", "type: String", presence(pres, "String"))
              else
                opts("expects :size", "on: #{on}", "method_call: true", "type: Integer", presence(pres, "String").sub('"x"', "1"))
              end
      route("D", "#{access} #{pres}", node:, lines: [child])
    end
  end

  # A block member of the anchor. A member declares no `default:` or `preprocess:` (refused at declaration), so
  # neither is generated.
  def block_routes(node: :company, variations: value_variations.reject { |_, pres| pres.include?("default") || pres == "transformed" })
    variations.map { |type, pres| route("B", "#{type} #{pres}", node:, member: opts("field :#{node}", TYPES[type][0], presence(pres, type))) }
  end

  RAW_PRESENCES = { "required" => "", "optional" => "allow_blank: true", "allow_nil" => "allow_nil: true",
                    "closed" => "if: -> { false }", "open" => "if: -> { true }" }.freeze

  def raw_routes(node: :company)
    (TYPES.keys - ["union"]).product(RAW_PRESENCES.keys).map do |type, pres|
      klass = TYPES[type][1] && "type: { klass: #{TYPES[type][1]} }"
      route("R", "#{type} #{pres}", node:, raw: "#{P}.member(:#{node}#{[klass, RAW_PRESENCES[pres]].compact.reject(&:empty?).map { ", #{_1}" }.join})")
    end
  end

  MODEL_PRESENCES = %w[required optional allow_nil closed open].freeze

  # A `model:` route whose generated id is the node: `company`'s id lands on `company_id`.
  def model_id_routes
    MODEL_PRESENCES.map do |pres|
      route("Mid", pres, node: :company_id, lines: ["expects :company, #{opts('on: :pin', MODEL, presence(pres, 'String'))}"])
    end
  end

  # A `model:` route whose own raw key is the node; its generated id is supplied beside it.
  def model_raw_routes(node: :company)
    MODEL_PRESENCES.map do |pres|
      route("Mraw", pres, node:, base: { "#{node}_id" => 1 },
                          lines: ["expects :#{node}, #{opts('on: :pin', MODEL, presence(pres, 'String'))}"])
    end
  end

  def placeholder_routes(node: :company)
    [route("PH", "Data", node:, anchor: "type: #{P}::Point")]
  end

  def bag_routes(node: :company)
    %w[Hash String].product(%w[required allow_nil optional]).map do |type, pres|
      klass = "klass: #{TYPES[type][1]}"
      route("Bag", "#{type} #{pres}", node:, anchor: "of: { values: { #{opts(klass, presence(pres, type))} } }")
    end
  end

  # Order varies only between routes that are both configs of the node itself.
  def ordered?(first, second) = [first, second].all? { |r| !r.lines.empty? && r.kind != "D" }

  def cells
    @cells ||= pair_cells + triple_cells + top_level_cells
  end

  def pair_cells
    node_routes = lambda do |node|
      { "E" => explicit_routes("E", node:), "A" => explicit_routes("A", node:), "D" => dotted_routes(node:),
        "B" => block_routes(node:), "R" => raw_routes(node:), "PH" => placeholder_routes(node:), "Bag" => bag_routes(node:) }
    end
    company = node_routes.call(:company).merge("Mraw" => model_raw_routes)
    company_id = node_routes.call(:company_id).merge("Mid" => model_id_routes, "Mraw" => model_raw_routes(node: :company_id))
    pairs = [%w[E A], %w[E D], %w[E B], %w[E R], %w[E Bag], %w[E PH], %w[D B], %w[D R], %w[D Bag], %w[D PH], %w[B PH],
             %w[D D], %w[B Bag], %w[R Bag]]
    out = company.merge("Mid" => company_id["Mid"]).flat_map { |k, rs| rs.map { |r| build("single #{k}", [r]) } }
    out += pairs.flat_map { |a, b| cross(company, a, b) }
    out += %w[E D B R Bag PH].flat_map { |k| cross(company, "Mraw", k) }
    out += (%w[E D B R Bag PH Mraw].flat_map { |k| cross(company_id, "Mid", k) })
    out
  end

  def cross(table, kind_a, kind_b)
    table.fetch(kind_a).product(table.fetch(kind_b)).flat_map do |ra, rb|
      next [] if kind_a == kind_b && ra.label[/\((\w+)/, 1] >= rb.label[/\((\w+)/, 1] # one child read each way

      # `E`x`A` is already an ordered product of two route lists, so it needs no second order.
      orders = ordered?(ra, rb) && kind_a != "E" ? [[ra, rb], [rb, ra]] : [[ra, rb]]
      orders.map { |routes| build("#{kind_a}x#{kind_b}", routes) }
    end
  end

  # Three routes at one node, over fewer variations each.
  def triple_cells
    vars = value_variations(%w[Hash untyped], %w[required optional allow_nil closed])
    few = %w[required optional closed]
    e = explicit_routes("E", variations: vars)
    a = explicit_routes("A", variations: vars)
    d = dotted_routes(presences: few)
    b = block_routes(variations: vars)
    mraw = model_raw_routes.select { |r| few.include?(r.label[/\((.*)\)/, 1]) }
    e.product(a, dotted_routes(presences: few, on: ":r_a")).map { |rs| build("ExAxD", rs) } +
      e.product(b, d).map { |rs| build("ExBxD", rs) } +
      mraw.product(b, d).map { |rs| build("MrawxBxD", rs) } +
      mraw.product(e, dotted_routes(presences: few, on: ":r_e")).map { |rs| build("MrawxExD", rs) }
  end

  # A top-level `model:` beside a top-level explicit field at its generated id, or beside a second `model:` route
  # whose own raw key that id is.
  def top_level_cells
    fields = value_variations.map { |type, pres| ["E(#{type} #{pres})", opts("expects :company_id", TYPES[type][0], presence(pres, type)), {}] } +
             MODEL_PRESENCES.map { |pres| ["Mraw(#{pres})", opts("expects :company_id", MODEL, presence(pres, "String")), { company_id_id: 1 }] }
    fields.product(MODEL_PRESENCES, [true, false]).map do |(label, field, base), mpres, model_first|
      model = opts("expects :company", MODEL, presence(mpres, "String"))
      decl = (model_first ? [model, field] : [field, model]).join("\n")
      routes = ["Mid(#{mpres})", label]
      Cell.new(pair: "top Midx#{label[/\A\w+/]}", id: "top #{routes.join(' + ')}#{' field-first' unless model_first}", decl:,
               path: [:company_id], base:, routes:)
    end
  end

  def build(pair, routes)
    node = routes.first.node
    members = routes.filter_map(&:member)
    raws = routes.filter_map(&:raw)
    anchor = routes.filter_map(&:anchor)
    anchor = ["type: Hash", *anchor] unless anchor.any? { |a| a.start_with?("type:") }
    anchor += ["shape: { members: [#{raws.join(', ')}] }"] unless raws.empty?
    # A `Data` anchor names its members only through a shape; give it one that does not touch the node.
    anchor += ["shape: { members: [#{P}.member(:other)] }"] if raws.empty? && members.empty? && anchor.first.include?("Point")
    inner = "expects :inner, on: :payload, as: :pin, #{anchor.join(', ')}"
    inner += " do\n  #{members.join("\n  ")}\nend" unless members.empty?
    decl = ["expects :payload, type: Hash", inner, *routes.flat_map(&:lines)].join("\n")
    Cell.new(pair:, id: "#{pair}: #{routes.map(&:label).join(' + ')}", decl:, path: [*ROOT, node], base: routes.map(&:base).reduce({}, :merge),
             routes: routes.map(&:label))
  end

  def declare(decl)
    klass = Class.new do
      include Axn
      class_eval(decl)
      def call = nil
    end
    [klass, klass.input_schema, klass.input_schema_residues]
  rescue ArgumentError, Axn::ContractViolation
    nil
  end

  def payload_for(cell, value)
    leaf = cell.base.merge(OMITTED.equal?(value) ? {} : { cell.path.last.to_s => value })
    return leaf.transform_keys(&:to_sym) if cell.path.size == 1

    cell.path[0...-1].reverse.reduce(leaf) { |acc, key| { key => acc } }
  end

  # The wire path a residue speaks for. A subfield the emitter leaves out is reported at the root, naming its own
  # `on:`; it speaks for that subfield's own position, with the anchor's alias (`pin`) and a route's (`r_a`, `r_e`)
  # read back to the wire path they name.
  def residue_path(residue, node_path)
    return residue.path unless residue.path.empty? && (m = residue.summary.match(/\A(\S+) \(on: (\S+)\) is validated/))

    on = m[2].split(".").map(&:to_sym)
    on = [*ROOT, *on.drop(1)] if on.first == :pin
    on = [*node_path, *on.drop(1)] if %i[r_a r_e].include?(on.first)
    [*on, m[1].to_sym]
  end

  # A residue explains a payload's divergence when it speaks for the node, an ancestor, or a descendant — a
  # descendant's check can fail on the node's own value, by requiring a key a String does not have. The model
  # lookup's own residue explains only a blank id, which names no record: the finder finds every other id sent.
  def explains?(residue, path, value)
    return false if residue.summary == Axn::Internal::Reflection::Schema::Vocabulary::MODEL_LOOKUP_RESIDUE && !non_nil_blank?(value)

    rpath = residue_path(residue, path)
    shorter, longer = [rpath, path].minmax_by(&:size)
    longer.first(shorter.size) == shorter
  end

  def non_nil_blank?(value) = !value.nil? && !OMITTED.equal?(value) && (value == false || (value.respond_to?(:empty?) && value.empty?))

  # The doctrine's stated exceptions (AGENTS.md, "exact at its core"), asked as narrowly as the payload allows.
  def stated_exception?(cell, value, satisfiable)
    return true if (value.nil? || (value.is_a?(Hash) && value.value?(nil))) && cell.id.include?("default") # a `nil` a `default:` fills (PRO-3589)

    # A blank-tolerant position's skipped blank (PRO-3244), only where the node admits some non-blank value.
    satisfiable && cell.id.match?(/optional|allow_blank/) && non_nil_blank?(value)
  end

  def schemer(schema) = JSONSchemer.schema(JSON.parse(JSON.generate(schema)), regexp_resolver: "ecma")

  # Yields `[cell, direction, payload]` for every divergence; returns `[declared, refused]`.
  def audit
    declared = 0
    refused = []
    cells.each do |cell|
      klass, schema, residues = declare(cell.decl)
      next refused << cell if klass.nil?

      declared += 1
      document = schemer(schema)
      verdicts = POOL.map do |value|
        payload = payload_for(cell, value)
        [value, payload, klass.call(**payload).ok?, document.valid?(JSON.parse(JSON.generate(payload)))]
      end
      satisfiable = verdicts.any? { |value, _, _, doc_ok| doc_ok && !OMITTED.equal?(value) && !value.nil? && !non_nil_blank?(value) }
      verdicts.each do |value, payload, runtime_ok, doc_ok|
        if runtime_ok && !doc_ok
          yield cell, :stricter, payload unless stated_exception?(cell, value, satisfiable)
        elsif doc_ok && !runtime_ok && residues.none? { |r| explains?(r, cell.path, value) }
          yield cell, :looser, payload
        end
      end
    end
    [declared, refused]
  end
end

RSpec.describe "several declarations meeting at one wire node, against runtime truth", :slow do
  it "never rejects a value the runtime accepts, and names every value it accepts that the runtime rejects" do
    stricter = []
    unreported = []
    declared, = MergeCornerProduct.audit do |cell, direction, payload|
      (direction == :stricter ? stricter : unreported) << "#{cell.id}: #{payload.inspect}"
    end

    expect(MergeCornerProduct.cells.size).to be > 5_000
    expect(declared).to be > 4_500
    expect(stricter).to be_empty, "stricter than the runtime:\n  #{stricter.first(40).join("\n  ")}"
    expect(unreported).to be_empty, "looser and unreported:\n  #{unreported.first(40).join("\n  ")}"
  end
end
