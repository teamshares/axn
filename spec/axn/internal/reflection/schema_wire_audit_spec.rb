# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "json_schemer"
require "active_support/core_ext/object/blank"
require "bigdecimal"
require "date"
require "json"

# Reflection's promise, stated in `docs/reference/class.md` ("What the schema promises"): inbound, the document
# is exact at its core and never STRICTER than the runtime anywhere, and whatever it leaves out it names as a
# residue (`input_schema_residues`); outbound, it may say MORE than the contract, never less. Every individual
# keyword is argued for in `schema_spec.rb`; nothing there asks the question this file asks, which is whether the
# document and the runtime agree when a REAL JSON Schema engine is the one reading it.
#
# So this walks the product of {declared type} x {validator spelling} x {tolerance} (x {gate}, inbound) and, for
# every cell, asks `json_schemer` — not a re-derivation of JSON Schema, and not the emitter's own opinion of what
# it wrote:
#
#   * OUTBOUND, the schema must never REJECT a value the action exposed successfully. The action settled ok, axn
#     serialized the value, and its own `output_schema` refuses it.
#   * INBOUND, the schema must never REJECT a value the runtime accepts — the direction a caller cannot recover
#     from, since a client validating against the document never sends the call — and every value it ACCEPTS
#     that the runtime rejects must be explained by a residue the class reports.
#
# Written after four consecutive rounds of review findings on PR #252 all landed in the same shape — each in the
# mirror of a keyword just changed — and the answer was to measure the whole surface at once instead of fixing
# another instance. It immediately found two the reviews had not: a narrowing that emptied a NULLABLE position
# to `enum: []` (the position exposes nil, so it admits nil and nothing else), and a nullable
# `comparison: { equal_to: }` emitted as a `const`, which cannot say "this number OR null". Both are fixed, and
# both are cells below.
#
# `json_schemer` compiles `pattern` against `regexp_resolver: "ecma"` (PRO-3441), not its Ruby-regex default:
# `pattern` is DEFINED as ECMA-262, and the two disagree on more than `^`/`$` line-vs-string anchoring — a
# multi-line probe below exists because that is exactly the case the default (Ruby) resolver got backwards:
# `format: { with: /\A[a-z]+\z/ }` emits `pattern: "^[a-z]+$"`, and against `"abc\ndef"` the RUBY-resolved
# document wrongly ACCEPTS it (Ruby's `^`/`$` are line anchors) while the runtime and the ECMA-resolved
# document both correctly refuse it. The emitted pattern was right all along; the ORACLE was reading it
# under the wrong grammar. A looseness nothing reports is exactly what that mismatch would have been read as had
# this file gone looking with the wrong tool.
module SchemaWireAudit
  OMITTED = Object.new.freeze # "the key is not sent at all", distinct from every JSON value including nil

  # One class per cell for the whole run, shared by every example that walks that cell, so each cell pays its
  # declaration once rather than once per example. The trade is that this Hash keeps every cell's class resident
  # until the process exits.
  def self.cells = (@cells ||= {})

  # The gate positions the defaulted walk varies: a default meeting a gated check is reached by the ungated
  # reading, one entry gate and one declaration gate; the other spellings are the plain walk's to vary.
  DEFAULTED_GATES = ["ungated", "entry if: false", "declaration if: false"].freeze

  # Literal kinds a declaration can name, for the literal-position walk.
  NamedLiteral = Class.new
  LiteralPoint = Struct.new(:x)
  LiteralData = Data.define(:x)
  LiteralString = Class.new(String)
end

RSpec.describe "the emitted schema against runtime truth", :slow do
  # Deliberately not `build_axn`: this needs the class object itself for its schemas, and a fresh one per cell.
  # An outbound class exposes whatever probe `with_outbound_probe` hands it, so one class serves every value.
  def declare(direction, decl)
    Class.new do
      include Axn
      direction == :in ? expects(:n, **decl) : exposes(:n, **decl)
      define_method(:call) { direction == :in ? nil : expose(:n, Thread.current[:schema_wire_audit_probe]) }
    end
  rescue StandardError
    nil # a declaration a guard refuses has no schema to audit; the guards have their own product spec
  end

  # The inbound class for a cell, declared once per run and keyed by the cell's names. `nil` when a guard refuses
  # the declaration, cached like any other answer.
  def inbound_cell(*key)
    return SchemaWireAudit.cells[key] if SchemaWireAudit.cells.key?(key)

    SchemaWireAudit.cells[key] = declare(:in, yield)
  end

  def outbound_cell(*key)
    key = [:out, *key]
    return SchemaWireAudit.cells[key] if SchemaWireAudit.cells.key?(key)

    SchemaWireAudit.cells[key] = declare(:out, yield)
  end

  def with_outbound_probe(value)
    Thread.current[:schema_wire_audit_probe] = value
    yield
  ensure
    Thread.current[:schema_wire_audit_probe] = nil
  end

  def types
    {
      "Integer" => Integer, "String" => String, "Array" => Array, "Hash" => Hash,
      "TrueClass" => TrueClass, "NilClass" => NilClass, "Numeric" => Numeric,
      "[String,Integer]" => [String, Integer], "[Integer,Float]" => [Integer, Float],
      "[String,NilClass]" => [String, NilClass], "[Array,Integer]" => [Array, Integer],
      "[TrueClass,Integer]" => [TrueClass, Integer],
      # Broad tokens: a SUPERTYPE of Numeric renders approximately (`Object` emits a `"string"` branch), which
      # is the family the satisfiability example below exists to guard.
      "Object" => Object, "Comparable" => Comparable
    }
  end

  def validators
    {
      "none" => {},
      "numericality:true" => { numericality: true },
      "num only_numeric" => { numericality: { only_numeric: true } },
      "num only_integer" => { numericality: { only_integer: true } },
      "num both" => { numericality: { only_numeric: true, only_integer: true } },
      "num gt:0" => { numericality: { greater_than: 0 } },
      "cmp gt:0" => { comparison: { greater_than: 0 } },
      "cmp equal_to:1" => { comparison: { equal_to: 1 } },
      "incl [1,2]" => { inclusion: { in: [1, 2] } },
      "incl [a,b]" => { inclusion: { in: %w[a b] } },
      "presence" => { presence: true },
      "length is:3" => { length: { is: 3 } },
      "format a-z" => { format: { with: /\A[a-z]+\z/ } },
      # The tier-2 checks the emitter leaves out and names: a pattern with no faithful ECMA spelling (`\s`), the
      # `without:` spelling, an exclusion set, and the blank axis on its own.
      "format \\s" => { format: { with: /\A\s*[a-z]+\z/ } },
      # Ruby LINE anchors: against `"a\nb"` the runtime matches a line, and an ECMA input anchor would not.
      "format ^$ multiline" => { format: { with: /^[a-z]+$/, multiline: true } },
      "format without" => { format: { without: /\d/ } },
      "exclusion [a]" => { exclusion: { in: %w[a] } },
      "absence" => { presence: false, absence: true },
      # Checks no keyword states at all: an accepted-value set, equality with a companion field, a callable, and
      # the numeric options with no bound to write.
      "acceptance" => { acceptance: true },
      "confirmation" => { confirmation: true },
      "validate" => { validate: ->(value) { "is one" if value == 1 } },
      # An option ActiveModel resolves per call: the schema cannot narrow for it, and must not render it.
      "num only_integer per call" => { numericality: { only_integer: ->(_record) { true } } },
      "cmp other_than:1" => { comparison: { other_than: 1 } },
      "num odd" => { numericality: { odd: true } },
    }
  end

  # The validator keys the corpus above does not exercise, each for a reason the audit cannot reach past.
  # Everything else a declaration accepts must appear, so a validator added to axn is a cell here before it is
  # a silent gap in the schema.
  def unaudited_validation_keys
    {
      uniqueness: "refused at declaration",
      model: "resolves a record, so it needs ActiveRecord (spec_rails)",
      of: "a position, walked by the position example",
      shape: "a position, walked by the nested examples",
      coerce: "a transform, not a check",
      if: "a gate, walked by the gate axis", unless: "a gate, walked by the gate axis",
      on: "refused at declaration", strict: "refused at declaration", message: "prose, not a check"
    }
  end

  it "exercises every validator a declaration accepts" do
    known = Axn::Core::Contract::ClassMethods::KNOWN_VALIDATION_KEYS.to_a
    # `type:` is every cell's other axis.
    audited = validators.values.flat_map(&:keys).uniq + [:type]

    expect(known - audited - unaudited_validation_keys.keys).to be_empty
  end

  # `optional:` is axn's nil-AND-blank tolerance, which is why it earns a column of its own here.
  def tolerances = { "required" => {}, "optional" => { optional: true } }

  # Only values a JSON document can carry, since that is what both directions are about.
  # `"a\nb"` is here specifically for `format a-z` (PRO-3441): `^`/`$` are LINE anchors under Ruby's regex
  # engine and STRING anchors under ECMA-262, so a probe with no embedded newline could never have told the
  # two grammars apart — every other value here is a single line, and the pattern axis would have kept
  # passing by accident whichever engine `schemer` used.
  #
  # Each sized type also gets a value on either side of the `length is:3` cell's bounds, so a dropped floor OR a
  # dropped ceiling is a value the document and the runtime disagree on.
  # An ordinary email sits beside the boundary probes: punctuation is what a `format:` cell most often meets.
  def probe_values
    [nil, true, false, 0, 1, 2, 1.5, 123, "", "a", "abc", "abcd", "1", "123", "a\nb", "user@example.com", [], [1], [1, 2, 3], [1, 2, 3, 4],
     {}, { "a" => 1 }, { "a" => 1, "b" => 2, "c" => 3 }, { "a" => 1, "b" => 2, "c" => 3, "d" => 4 }]
  end

  # A tolerated BLANK passes every validator — ActiveModel skips it before any of them runs — while the emitted
  # `enum`/`pattern`/narrowing still describes only the non-blank values. So a blank-tolerant position accepts
  # `""`, `[]`, `{}` and `false` at runtime and its document refuses them: STRICTER than the runtime, in the
  # exact core, and the one such divergence this file still excludes by name. A blank-tolerant `length:` is
  # already reflected as a residue instead; the literal-set and pattern half is PRO-3244's (widening the set
  # with the blank is exact for a container and not for a String, whose blank is any run of whitespace).
  def known_blank_tolerance_divergence?(tolerance_name, value)
    tolerance_name == "optional" && !value.nil? && value.blank?
  end

  # A Ruby class the wire cannot carry a distinct form of: the runtime wants an INSTANCE and JSON has only its
  # shape. `type: Float` emits `"number"` and a JSON `0` is an Integer to Ruby; a Symbol, Time or BigDecimal is
  # reached only through a String or number that axn will refuse. Inbound-only, and inherent rather than
  # unfixed — there is no keyword that says "a number written with a decimal point".
  def no_distinct_wire_form = ["[Integer,Float]", "Numeric"]

  def each_cell
    types.each do |tname, tklass|
      validators.each do |vname, vopts|
        tolerances.each do |tolname, tol|
          yield tname, tklass, vname, vopts, tolname, tol
        end
      end
    end
  end

  def schemer(schema)
    JSONSchemer.schema(JSON.parse(JSON.generate(schema)), regexp_resolver: "ecma")
  end

  # The OUTBOUND direction, and the sharp one: the action settled ok and axn serialized the value, so a document
  # that refuses it is refusing output its own contract produced.
  it "never rejects outbound a value the action exposed successfully" do
    wrong = []
    exposed = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      probe_values.each do |value|
        next if known_blank_tolerance_divergence?(tolname, value)

        klass = outbound_cell(tname, vname, tolname) { { type: tklass }.merge(vopts).merge(tol) }
        next if klass.nil?

        result = begin
          with_outbound_probe(value) { klass.call }
        rescue StandardError
          next
        end
        next unless result.ok?

        rendered = begin
          Axn::Extensions::Serialization.render(result)
        rescue StandardError
          next
        end
        exposed += 1
        errors = schemer(klass.output_schema).validate(JSON.parse(JSON.generate(rendered))).to_a
        next if errors.empty?

        wrong << "#{tname} / #{vname} / #{tolname}: exposed #{value.inspect}, serialized " \
                 "#{rendered['n'].inspect}, schema #{klass.output_schema[:properties][:n].inspect} " \
                 "-> #{errors.first['error']}"
      end
    end

    # The product has not silently stopped exercising anything — an audit that reaches no successful exposure
    # would pass while measuring nothing at all.
    expect(exposed).to be > 200
    expect(wrong).to be_empty, "these schemas reject output the action produced:\n  #{wrong.join("\n  ")}"
  end

  # The corollary neither direction above catches, and the one that has bitten hardest. An emitted node that
  # NOTHING satisfies is "stricter", so the inbound check licenses it — but `guards-and-projections.md` forbids
  # an unsatisfiable node for a SATISFIABLE contract, and every instance so far has been a narrowing that read
  # the emitted type as proof about the declared token: an ABSENT type (`type: Numeric` outbound), then an
  # APPROXIMATE one (`type: Object` renders as a `"string"` branch). Both emptied a position a plain `1`
  # satisfies. Asked of both schemas, since the same narrowings run in both directions.
  it "never emits a node nothing satisfies for a contract something satisfies" do
    wrong = []
    live = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      klass = inbound_cell(tname, vname, tolname, "ungated") { { type: tklass }.merge(vopts).merge(tol) }
      next if klass.nil?

      accepted = probe_values.select do |value|
        klass.call(n: value).ok?
      rescue StandardError
        false
      end
      next if accepted.empty? # the contract admits nothing, so an unsatisfiable node is the faithful projection

      live += 1
      document = schemer(klass.input_schema)
      next if probe_values.any? { |value| document.valid?({ "n" => value }) }

      wrong << "#{tname} / #{vname} / #{tolname}: runtime accepts #{accepted.first.inspect}, document accepts " \
               "nothing at all — #{klass.input_schema[:properties][:n].inspect}"
    end

    expect(live).to be > 200
    expect(wrong).to be_empty, "these contracts are satisfiable and their schemas are not:\n  #{wrong.join("\n  ")}"
  end

  # A gate the audit holds CLOSED, at each position one can be written: on the whole declaration, and on a
  # single validator entry. Closed is the reading under which the runtime accepts the most, so it is the one a
  # document stricter than the runtime is caught by — and the schema is the same whatever the gate evaluates to,
  # since reflection never runs a condition.
  def closed_gates
    {
      "ungated" => ->(decl) { decl },
      "declaration if: false" => ->(decl) { decl.merge(if: -> { false }) },
      # Only the `type:` entry gated, so the others run on every call beside a type that does not. Gating every
      # entry at once cannot show a check that leaned on the type being there.
      "type entry if: false" => ->(decl) { decl.merge(type: { klass: decl[:type], if: -> { false } }) },
      "entry if: false" => lambda { |decl|
        decl.to_h do |key, opt|
          next [key, opt] if %i[type optional].include?(key)

          [key, opt.is_a?(Hash) ? opt.merge(if: -> { false }) : { if: -> { false } }]
        end
      },
      # A declaration gate every entry overrides with a blank nested one: ActiveModel drops the shared gate for
      # that key and runs the entry on every call, so the declaration only LOOKS gated. The inferred presence
      # check keeps the shared gate.
      "declaration if: false, overridden per entry" => lambda { |decl|
        decl.to_h do |key, opt|
          next [key, opt] if key == :optional
          next [key, { klass: opt, if: nil }] if key == :type

          [key, opt.is_a?(Hash) ? opt.merge(if: nil) : { if: nil }]
        end.merge(if: -> { false })
      },
    }
  end

  # The one direction BOTH tiers promise: whatever the runtime accepts, the document accepts. A stricter
  # document is invisible to the caller it misleads — a client validating against it never sends the call the
  # runtime would have taken — while a looser one costs a round-trip to a named runtime error. So this is asked
  # of every cell with every gate closed, and the only exclusions are the named, pre-existing ones.
  def omitted = SchemaWireAudit::OMITTED

  it "never rejects inbound a value the runtime accepts" do
    wrong = []
    accepted = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      closed_gates.each do |gname, gate|
        next if gname != "ungated" && vopts.empty?

        klass = inbound_cell(tname, vname, tolname, gname) { gate.call({ type: tklass }.merge(vopts)).merge(tol) }
        next if klass.nil?

        document = schemer(klass.input_schema)
        # An omitted key is a probe of its own: requiredness is tier 1, and a gated presence check is the case a
        # value-only walk can never see.
        (probe_values + [omitted]).each do |value|
          next if known_blank_tolerance_divergence?(tolname, value)

          runtime_ok = begin
            (omitted.equal?(value) ? klass.call : klass.call(n: value)).ok?
          rescue StandardError
            false
          end
          next unless runtime_ok

          accepted += 1
          next if document.valid?(omitted.equal?(value) ? {} : { "n" => value })

          wrong << "#{tname} / #{vname} / #{tolname} / #{gname}: runtime accepts #{value.inspect}, document " \
                   "rejects it, schema #{klass.input_schema[:properties][:n].inspect}"
        end
      end
    end

    expect(accepted).to be > 1000
    expect(wrong).to be_empty, "these schemas reject what the runtime accepts:\n  #{wrong.join("\n  ")}"
  end

  # A callable's or an opaque object's only rendering is an address, which would change the document on every boot. The corpus
  # carries callables (`validate:`, per-call options, Proc gates), so no emitted document may contain one.
  it "never renders a callable's address into a document" do
    rendered = []
    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      closed_gates.each do |gname, gate|
        next if gname != "ungated" && vopts.empty?

        klass = inbound_cell(tname, vname, tolname, gname) { gate.call({ type: tklass }.merge(vopts)).merge(tol) }
        next if klass.nil?

        rendered << "#{tname} / #{vname} / #{tolname} / #{gname}" if JSON.generate(klass.input_schema).match?(/#<[^"]*0x\h+/)
      end
    end

    expect(rendered).to be_empty, "these documents render a callable:\n  #{rendered.join("\n  ")}"
  end

  # The same promise for every other token a document names: an anonymous class or module renders as its object
  # address, so each position that names a token — a declared `type:` and union, an `of:` bag and a map axis, a
  # `model:` class and its `id_type:`, a numeric class, a constant set under an anonymous class, a bound that is an
  # instance of one — is declared with anonymous ones, in both directions.
  it "never renders any token's address into a document" do
    anon = Class.new
    anon.const_set(:Inner, Class.new)
    numeric = Class.new(Numeric)
    mod = Module.new
    model = Class.new { def self.fetch(id) = id }
    tokens = { "class" => anon, "nested constant" => anon::Inner, "module" => mod, "numeric" => numeric,
               "singleton" => Object.new.singleton_class }
    declarations = tokens.flat_map do |label, token|
      [
        ["#{label} type", :in, { type: token }], ["#{label} union", :in, { type: [token, String] }],
        ["#{label} of", :in, { type: Array, of: token }], ["#{label} map", :in, { type: Hash, of: { values: { klass: token } } }],
        ["#{label} keys", :in, { type: Hash, of: { keys: { klass: token } } }],
        ["#{label} id_type", :in, { model: { klass: model, finder: :fetch, id_type: token } }],
        ["#{label} out type", :out, { type: token }], ["#{label} out of", :out, { type: Array, of: token }]
      ]
    end
    declarations += [
      ["anonymous model", :in, { model: { klass: Class.new { def self.fetch(id) = id }, finder: :fetch } }],
      ["instance equal_to", :in, { type: Integer, comparison: { equal_to: anon.new } }],
      ["instance in a validate: residue", :in, { type: Integer, numericality: { greater_than: anon.new } }],
    ]

    declared = 0
    rendered = declarations.filter_map do |label, direction, decl|
      klass = declare(direction, decl)
      next if klass.nil?

      declared += 1
      schema = direction == :in ? klass.input_schema : klass.output_schema
      label if JSON.generate(schema).match?(/0x\h{4,}/)
    end

    expect(declared).to be > 35
    expect(rendered).to be_empty, "these documents render a token's address:\n  #{rendered.join("\n  ")}"
  end

  # A declaration's own literals are written into the document as data: an `inclusion:` set as `enum`, a `default:`
  # as `default`. So every kind of value a caller can put in a literal position is declared at each one, in both
  # directions, and the document must hold only values JSON carries as they stand (no live object for an encoder to
  # render as an address, nothing it refuses), and inbound every `enum` member it advertises must be a value the
  # runtime accepts — through a tool invoker's coercion, the stated spelling of a type whose wire form is a String —
  # unless the class names a residue. The positions that name a literal in prose instead (`exclusion:`, `equal_to:`,
  # `acceptance:`) are the controls.
  def literal_kinds
    {
      "class" => SchemaWireAudit::NamedLiteral, "anonymous class" => Class.new, "module" => Comparable, "object" => Object.new,
      "Struct" => SchemaWireAudit::LiteralPoint.new(1), "Data" => SchemaWireAudit::LiteralData.new(x: 1), "Range" => (1..2),
      "Regexp" => /a/, "Set" => Set[1], "Symbol" => :a, "Time" => Time.utc(2026, 1, 1), "Date" => Date.new(2026, 1, 1),
      "Complex" => Complex(1, 2), "BigDecimal" => BigDecimal("1.5"), "Rational" => Rational(3, 2), "Infinity" => Float::INFINITY,
      "binary" => "\xFF".b, "Latin-1" => (+"caf\xE9").force_encoding(Encoding::ISO_8859_1), "String subclass" => SchemaWireAudit::LiteralString.new("a"),
      "Symbol-keyed Hash" => { a: 1 }, "String-keyed Hash" => { "a" => 1 }, "Array of Symbol" => [:a], "String" => "a", "Integer" => 1,
      "Float" => 1.5, "true" => true
    }
  end

  # [direction, declaration, where the advertised `enum` sits, the payload sending one of its members].
  def literal_positions
    member = ->(v) { Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { inclusion: { in: [v] } }) }
    {
      "inclusion" => [:in, ->(v) { { inclusion: { in: [v] } } }, [], ->(m) { m }],
      "inclusion beside a String" => [:in, ->(v) { { inclusion: { in: [v, "a"] } } }, [], ->(m) { m }],
      "inclusion under its own class" => [:in, ->(v) { { type: v.class, inclusion: { in: [v] } } }, [], ->(m) { m }],
      "element inclusion" => [:in, ->(v) { { type: Array, of: { inclusion: { in: [v] } } } }, [:items], ->(m) { [m] }],
      "map value inclusion" => [:in, ->(v) { { type: Hash, of: { values: { inclusion: { in: [v] } } } } }, [:additionalProperties], ->(m) { { "k" => m } }],
      "map key inclusion" => [:in, ->(v) { { type: Hash, of: { keys: { inclusion: { in: [v, "a"] } } } } }, [:propertyNames], ->(m) { { m => 1 } }],
      "member inclusion" => [:in, ->(v) { { type: Hash, shape: { members: [member.call(v)] } } }, %i[properties m], ->(m) { { "m" => m } }],
      "default" => [:in, ->(v) { { default: v } }, nil, nil],
      "exclusion" => [:in, ->(v) { { exclusion: { in: [v] } } }, nil, nil],
      "equal_to" => [:in, ->(v) { { comparison: { equal_to: v } } }, nil, nil],
      "acceptance" => [:in, ->(v) { { acceptance: { accept: [v] } } }, nil, nil],
      "output inclusion" => [:out, ->(v) { { inclusion: { in: [v, "a"] } } }, nil, nil],
      "output element inclusion" => [:out, ->(v) { { type: Array, of: { inclusion: { in: [v, "a"] } } } }, nil, nil],
      "output default" => [:out, ->(v) { { default: v } }, nil, nil],
    }
  end

  # Every leaf a value JSON carries as it stands: no live object, no number or String an encoder refuses.
  def json_native?(node)
    case node
    when Hash then node.all? { |key, value| (key.instance_of?(Symbol) || json_native?(key)) && json_native?(value) }
    when Array then node.all? { |value| json_native?(value) }
    when nil, true, false, Integer then true
    when Float then node.finite?
    when String then node.instance_of?(String) && !Axn::Internal::Text.utf8_rendering(node).nil?
    else false
    end
  end

  it "writes only JSON literals into a document, and advertises only members the runtime accepts" do
    live = []
    rejected = []
    advertised = 0
    declared = 0

    literal_kinds.each do |kname, value|
      literal_positions.each do |pname, (direction, decl, enum_path, payload)|
        klass = declare(direction, decl.call(value))
        next if klass.nil?

        declared += 1
        schema = direction == :in ? klass.input_schema : klass.output_schema
        encoded = begin
          JSON.generate(schema)
        rescue StandardError => e
          e
        end
        live << "#{kname} / #{pname}: #{schema[:properties][:n].inspect}" unless json_native?(schema) && encoded.is_a?(String) && !encoded.match?(/0x\h{4,}/)
        next if enum_path.nil? || !encoded.is_a?(String)

        enum = JSON.parse(encoded).dig("properties", "n", *enum_path.map(&:to_s), "enum")
        next if enum.nil? || klass.input_schema_residues.any?

        coerced = Class.new(klass) { coerce_input_types true }
        enum.compact.each do |wire|
          advertised += 1
          next if coerced.call(n: payload.call(wire)).ok?

          rejected << "#{kname} / #{pname}: advertises #{wire.inspect}, which the runtime rejects"
        end
      end
    end

    expect(declared).to be > 250
    expect(advertised).to be > 40
    expect(live).to be_empty, "these documents carry a value with no JSON literal:\n  #{live.join("\n  ")}"
    expect(rejected).to be_empty, "these documents advertise a literal the runtime rejects:\n  #{rejected.join("\n  ")}"
  end

  # `default:` is not a validator, so the walk above never declares one — and a default changes what reaches
  # every check: an omitted value becomes the default, which a gated check may then reject only on some calls.
  # Two defaults per cell: the type's blank (the value a presence check turns on), and one the plain cell
  # accepts. An explicit nil is not probed: a default fills one too, and the schema states the field's declared
  # nullability rather than widening for it (the stated exception; omitting the key is the reflected spelling).
  def default_variants(tklass, plain)
    blank = { String => "", Array => [], Hash => {} }[tklass]
    accepted = probe_values.find do |value|
      !value.nil? && plain.call(n: value).ok?
    rescue StandardError
      false
    end
    { "blank default" => blank, "accepted default" => accepted }.compact
  end

  it "never rejects inbound a value the runtime accepts when the field is defaulted" do
    wrong = []
    accepted = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      closed_gates.slice(*SchemaWireAudit::DEFAULTED_GATES).each do |gname, gate|
        next if gname != "ungated" && vopts.empty?

        decl = gate.call({ type: tklass }.merge(vopts)).merge(tol)
        plain = inbound_cell(tname, vname, tolname, gname) { decl }
        next if plain.nil?

        default_variants(tklass, plain).each do |dname, default|
          klass = declare(:in, decl.merge(default:))
          next if klass.nil?

          document = schemer(klass.input_schema)
          (probe_values.compact + [omitted]).each do |value|
            next if known_blank_tolerance_divergence?(tolname, value)

            runtime_ok = begin
              (omitted.equal?(value) ? klass.call : klass.call(n: value)).ok?
            rescue StandardError
              false
            end
            next unless runtime_ok

            accepted += 1
            next if document.valid?(omitted.equal?(value) ? {} : { "n" => value })

            wrong << "#{tname} / #{vname} / #{tolname} / #{gname} / #{dname}: runtime accepts #{value.inspect}, " \
                     "document rejects it, schema #{klass.input_schema[:properties][:n].inspect}"
          end
        end
      end
    end

    expect(accepted).to be > 1000
    expect(wrong).to be_empty, "these defaulted schemas reject what the runtime accepts:\n  #{wrong.join("\n  ")}"
  end

  # The exact core, cell by cell: a declared type JSON Schema has a spelling for, carrying only checks the core
  # states — presence, a literal `inclusion:` set of that type, a literal numeric bound on a number, a literal
  # `length:` on a sized type. Here the document must agree with the runtime in BOTH directions and report nothing:
  # a residue in the core is a bug, so a keyword the core drops cannot hide behind one.
  def tier_one_cells
    {
      "String" => [String, ["none", "presence", "length is:3", "incl [a,b]"]],
      "Integer" => [Integer, ["none", "presence", "num gt:0", "cmp gt:0", "cmp equal_to:1", "incl [1,2]"]],
      "Array" => [Array, ["none", "presence", "length is:3"]],
      "Hash" => [Hash, ["none", "presence", "length is:3"]],
      "TrueClass" => [TrueClass, %w[none presence]],
    }
  end

  it "states its exact core exactly, and reports nothing there" do
    wrong = []
    compared = 0

    tier_one_cells.each do |tname, (tklass, vnames)|
      vnames.each do |vname|
        klass = declare(:in, { type: tklass }.merge(validators.fetch(vname)))
        next wrong << "#{tname} / #{vname}: refused at declaration" if klass.nil?

        residues = klass.input_schema_residues
        wrong << "#{tname} / #{vname}: reports #{residues.map(&:summary).inspect}" if residues.any?
        document = schemer(klass.input_schema)
        (probe_values + [omitted]).each do |value|
          runtime_ok = begin
            (omitted.equal?(value) ? klass.call : klass.call(n: value)).ok?
          rescue StandardError
            false
          end
          accepted = document.valid?(omitted.equal?(value) ? {} : { "n" => value })
          compared += 1
          next if accepted == runtime_ok

          wrong << "#{tname} / #{vname}: runtime #{runtime_ok ? 'accepts' : 'rejects'} #{value.inspect}, document " \
                   "#{accepted ? 'accepts' : 'rejects'} it — #{klass.input_schema[:properties][:n].inspect}"
        end
      end
    end

    expect(compared).to be > 300
    expect(wrong).to be_empty, "the exact core disagrees with the runtime:\n  #{wrong.join("\n  ")}"
  end

  # Gates the looseness walk holds OPEN as well as closed: an open gate is the reading under which the
  # runtime rejects the most, so it is where a document that left a gated check out is loosest.
  def all_gates
    closed_gates.merge(
      "declaration if: true" => ->(decl) { decl.merge(if: -> { true }) },
      "entry if: true" => lambda { |decl|
        decl.to_h do |key, opt|
          next [key, opt] if %i[type optional].include?(key)

          [key, opt.is_a?(Hash) ? opt.merge(if: -> { true }) : { if: -> { true } }]
        end
      },
    )
  end

  # The INBOUND looseness direction. The schema may say less than the runtime — beyond its exact core, a
  # check it cannot state faithfully is left out — but never silently: a value the document accepts and the
  # runtime rejects must be explained by a residue the class reports (`input_schema_residues`, the same list
  # rendered into each property's `description`). A looseness with no residue is a defect in either tier.
  it "reports every value it accepts inbound that the runtime rejects" do
    wrong = []
    checked = 0
    explained = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      next if no_distinct_wire_form.include?(tname)

      all_gates.each do |gname, gate|
        next if gname != "ungated" && vopts.empty?

        klass = inbound_cell(tname, vname, tolname, gname) { gate.call({ type: tklass }.merge(vopts)).merge(tol) }
        next if klass.nil?

        document = schemer(klass.input_schema)
        reported = klass.input_schema_residues.any?
        probe_values.each do |value|
          next if known_blank_tolerance_divergence?(tolname, value)

          runtime_ok = begin
            klass.call(n: value).ok?
          rescue StandardError
            false
          end
          checked += 1
          next unless document.valid?({ "n" => value }) && !runtime_ok

          if reported
            explained += 1
            next
          end

          wrong << "#{tname} / #{vname} / #{tolname} / #{gname}: document accepts #{value.inspect}, runtime " \
                   "rejects it, and nothing is reported — schema #{klass.input_schema[:properties][:n].inspect}"
        end
      end
    end

    expect(checked).to be > 1000
    # The residue path is reached, or "reported" would be passing by never being asked.
    expect(explained).to be > 100
    expect(wrong).to be_empty, "these schemas accept what the runtime rejects without saying so:\n  #{wrong.join("\n  ")}"
  end

  # The same two inbound questions at a POSITION rather than a field: an array's element and a map's value are
  # declared through an `of:` bag, which the emitter projects on a path of its own — so a residue the field path
  # records can still go missing there, and only a walk over positions would see it.
  def positions
    {
      "element" => [->(bag) { { type: Array, of: bag } }, ->(value) { [value] }],
      "map value" => [->(bag) { { type: Hash, of: { values: bag } } }, ->(value) { { "k" => value } }],
    }
  end

  def each_position_cell
    positions.each do |pname, (wrap_decl, wrap_value)|
      types.each do |tname, tklass|
        next if no_distinct_wire_form.include?(tname)

        validators.each do |vname, vopts|
          klass = declare(:in, wrap_decl.call({ klass: tklass }.merge(vopts)))
          next if klass.nil?

          yield "#{pname} / #{tname} / #{vname}", klass, wrap_value
        end
      end
    end
  end

  def position_verdicts(klass, wrap_value)
    probe_values.map do |value|
      wire = wrap_value.call(value)
      runtime_ok = begin
        klass.call(n: wire).ok?
      rescue StandardError
        false
      end
      [value, runtime_ok, schemer(klass.input_schema).valid?(JSON.parse(JSON.generate("n" => wire)))]
    end
  end

  it "never rejects at a position a value the runtime accepts there, and reports what it accepts that it rejects" do
    stricter = []
    unreported = []
    cells = 0

    each_position_cell do |label, klass, wrap_value|
      cells += 1
      reported = klass.input_schema_residues.any?
      position_verdicts(klass, wrap_value).each do |value, runtime_ok, accepted|
        stricter << "#{label}: runtime accepts #{value.inspect}, document rejects it" if runtime_ok && !accepted
        unreported << "#{label}: document accepts #{value.inspect}, runtime rejects it" if accepted && !runtime_ok && !reported
      end
    end

    expect(cells).to be > 150
    expect(stricter).to be_empty, "these positions reject what the runtime accepts:\n  #{stricter.join("\n  ")}"
    expect(unreported).to be_empty, "these positions accept what the runtime rejects without saying so:\n  #{unreported.join("\n  ")}"
  end

  # The three examples above declare a single FLAT field, which leaves the whole nested-subfield surface
  # outside the audit — and that is where PRO-3399 lived: an explicit subfield node at a key an ancestor
  # `shape:` also described replaced the member's emitted property instead of conjoining with it, so the
  # document advertised a bare object for a position the runtime still held to every member the ancestor
  # declared. No single keyword was wrong; the node was simply missing half its contract, which is exactly
  # the shape of defect a keyword-by-keyword spec cannot see and a real engine can.
  #
  # So this walks {ancestor member} x {explicit node} x {payload} and asks the same INBOUND question: a
  # document that accepts what the runtime rejects is the failure. The nesting is spelled both ways in the
  # matrix — an explicit `on:` node and the dotted `on:` that reaches the same wire path — because the two
  # are the same contract and the defect was the disagreement between them.
  # PRO-3405 closed the conjunction gap: a member the node's own type "cannot nest" is no longer dropped
  # outright — it rides alongside as a sibling `allOf` branch instead (conjoin_shape_member_property), so
  # every row this walk exercises now agrees with the runtime. What remains excluded is a DIFFERENT, older
  # gap (`apply_implicit_node!`'s early return, unrelated to PRO-3405): a deep subfield reached only through
  # an IMPLICIT intermediate under a non-nestable member has no explicit node to hang an `allOf` branch off
  # of at all — the member's own type IS the whole story at that key, and it cannot host a deeper object
  # structure. That is the divergence `docs/recipes/authoring-tool-adapters.md` already documents (a deep
  # subfield with no JSON representation, omitted with a `logger.warn`) and it is asked of the EMITTER's own
  # `dropped_deep_subfields`, not re-derived, so the exclusion can never drift from what is actually dropped
  # (measured: this walk reported 58 divergences across 19 rows before PRO-3399, 22 across 6 rows after it,
  # and 0 after PRO-3405 conjoined every row but this one).
  #
  # NOT excluded, deliberately: the nullability cap PRO-3399 added applies to these members too (it is
  # charged on every colliding member, merged or not), and `schema_spec.rb` asserts that directly — so the
  # one thing this walk stops watching here is watched there.
  def unrepresentable_deep_drop?(klass)
    !Axn::Internal::Reflection::Schema.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs).empty?
  end

  # What the document reports it leaves out, asked of the public reader an adapter reads — not re-derived, so
  # a row explained here is exactly a row whose document admits it cannot describe the contract, and one that
  # stops reporting a residue stops being explained on the same commit.
  def residues_for(klass) = klass.input_schema_residues

  def nested_members
    {
      "object member" => proc { field :inner, type: Hash },
      "object member with a required String" => proc { field(:inner, type: Hash) { field :a, type: String } },
      "object member with a required Integer" => proc { field(:inner, type: Hash) { field :a, type: Integer } },
      "nil-tolerant object member" => proc { field(:inner, type: Hash, allow_nil: true) { field :a, type: String } },
      "map member" => proc { field :inner, type: Hash, of: { keys: { klass: Symbol }, values: { klass: String } } },
      "mixed-union member" => proc { field :inner, type: [Hash, Array] },
      "scalar member" => proc { field :inner, type: String },
      # A GATED member, whose checks are skipped on the calls its condition closes. Conjoining one
      # unconditionally can project a satisfiable contract onto a node nothing satisfies — the failure
      # example 2 below exists for — and no member in this axis was gated, so that whole interaction went
      # unwatched. Gated SCALAR specifically: a gated Hash member's type can still hold beside the node's,
      # so it never reaches the contradiction.
      "gated scalar member" => proc { field :inner, type: String, if: -> { false } },
      # An UNCONDITIONAL type beside an unrelated CONDITIONAL entry — the shape of every inbound breach the
      # narrowed exclusion above now lets this walk see. Standing the whole side down here drops a check
      # that runs on every call, which is the one direction reflection may never take; the axis had no such
      # row, so nothing measured it.
      "partly gated scalar member" => proc { field :inner, type: String, inclusion: { in: %w[s], if: -> { false } } },
      # No gated LITERAL member here, deliberately. This example reads "no probe payload satisfies the
      # document" as its proxy for unsatisfiable, and that proxy cannot police a literal collision: with a
      # payload-reachable literal on the member the runtime accepts nothing either and the row is skipped,
      # and with one on the node the surviving document is satisfiable by a value outside the payload set,
      # which is licensed strictness rather than emptiness. Both arrangements were measured by mutation and
      # neither moved. The literal, numeric-bound, size-bound and pattern axes are covered directly in
      # `schema_spec.rb`, each verified by mutation there.
      #
      # PRO-3441. Everything above is a STRUCTURAL collision (a type, a child, a shape) — none carries a
      # VALUE-level keyword the other side also carries, so `merge_shape_member_property`'s keyword-by-keyword
      # reconciliation (`:enum`, the size bounds, the map axes) never actually runs in this walk; it only
      # ever takes the trivial "one side is empty" path. These four rows put a real value constraint on the
      # member side of an otherwise object-shaped position, paired below with the mirror on the node side,
      # so the reconciliation is exercised rather than merely present.
      "literal object member" => proc { field :inner, type: Hash, inclusion: { in: [{ "b" => 2 }] } },
      "floor object member" => proc { field :inner, type: Hash, length: { minimum: 2 } },
      "ceiling object member" => proc { field :inner, type: Hash, length: { maximum: 4 } },
      "map values member" => proc { field :inner, type: Hash, of: { values: { klass: Integer } } },
      "map keys member" => proc { field :inner, type: Hash, of: { keys: { klass: String, length: { minimum: 2 } } } },
      # PRO-3441 round 2 (PR #285, Codex): a NESTED (object-shaped) values axis is a different case from
      # every other map-axis row above, which are all flat/scalar — this exercises the stand-down
      # `conjoin_map_value_axes` takes instead of duplicating a whole subtree per colliding property (see
      # `flat_axis_schema?`), which is meant to be excluded from the acceptance tripwire by its own
      # reported residue, not silently unsound.
      "nested map values member" => proc {
        member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String } })
        field :inner, type: Hash, of: { values: { klass: Hash, shape: { members: [member] } } }
      },
    }
  end

  def nested_nodes
    {
      "explicit node" => proc { expects :inner, on: :payload, type: Hash },
      "explicit nil-tolerant node" => proc { expects :inner, on: :payload, type: Hash, allow_nil: true },
      "explicit node with a child" => proc {
        expects :inner, on: :payload, type: Hash
        expects :c, on: :inner, type: String
      },
      "explicit node with its own shape" => proc {
        expects(:inner, on: :payload, type: Hash) { field :b, type: String }
      },
      "dotted on: (no explicit node)" => proc { expects :c, on: "payload.inner", type: String },
      # PRO-3405: the node ITSELF is non-nestable (a mixed union, not a plain Hash) — every other node in
      # this axis is `type: Hash`, so this is the one row that reaches conjoin_shape_member_property's
      # "neither side is object-shaped" branch at the TOP level rather than at a nested key. Without it,
      # the fix's least-tested branch is unguarded.
      "explicit non-nesting node" => proc { expects :inner, on: :payload, type: [Hash, Array] },
      # A node that TRANSFORMS the value it judges. Its keywords describe the coercion's target, not the
      # wire form the member's own check reads, so the emitter stands down rather than conjoining them —
      # and these are the only rows in this walk that produce a residue. Without them the stand-down is
      # unexercised and this walk's clean run says nothing about it.
      "coercing node" => proc { expects :inner, on: :payload, type: { klass: Integer, coerce: true } },
      "coercing node with a bound" => proc {
        expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { equal_to: 5 }
      },
      "preprocessing node" => proc { expects :inner, on: :payload, type: String, preprocess: ->(v) { v } },
      # An identity Proc leaves the wire value and the checked value the same, so it cannot show a check stated
      # on the wrong one. A Proc that REPLACES the value can: the runtime then accepts every wire form, so any
      # keyword the node or its children state on the wire value rejects a call the runtime takes. It passes nil
      # through: a transformed field keeps its declared requiredness and nullability, the stated exception.
      "repairing node with a child" => proc {
        expects :inner, on: :payload, type: Hash, preprocess: ->(v) { v.nil? ? v : { c: "z" } }
        expects :c, on: :inner, type: String
      },
      # PRO-3441. The mirror of the four member-side rows above, so a value-level collision actually
      # arises: two `inclusion:` sets (the exact PRO-3405 shape), two SAME-keyword size bounds (so
      # `minProperties`/`maxProperties` COLLIDE rather than merely appear on one side), and two `of:` axes
      # naming DIFFERENT value/key types.
      "literal node" => proc { expects :inner, on: :payload, type: Hash, inclusion: { in: [{ "c" => 3 }] } },
      "floor node" => proc { expects :inner, on: :payload, type: Hash, length: { minimum: 3 } },
      "ceiling node" => proc { expects :inner, on: :payload, type: Hash, length: { maximum: 2 } },
      "map values node" => proc { expects :inner, on: :payload, type: Hash, of: { values: { klass: String } } },
      "map keys node" => proc { expects :inner, on: :payload, type: Hash, of: { keys: { klass: String, length: { minimum: 4 } } } },
      # PRO-3441. A nil-tolerant node WITH a child, paired below against a non-nilable MEMBER with none —
      # `apply_nested_subfields!` (having a child to nest) sets this node's OWN type nullable from its own
      # representative alone, and `apply_explicit_child!`'s null_ok cap is the only thing that then reads
      # the COLLIDING member's nilability and downgrades it back. Every other nil-tolerant node row here is
      # childless, so `apply_nested_subfields!` returns before ever touching `:type` and this cap has
      # nothing to correct — this row is the one place it is exercised at all.
      # A GATED node that nests a child: its nil rejection is skipped on the calls the gate closes, so the node's
      # own nullability — decided where children are nested, not where the property is built — must read the
      # gate closed as well.
      "explicit gated node with a child" => proc {
        expects :inner, on: :payload, type: Hash, if: -> { false }
        expects :c, on: :inner, type: String, optional: true
      },
      "explicit nil-tolerant node with a child" => proc {
        expects :inner, on: :payload, type: Hash, allow_nil: true
        expects :c, on: :inner, type: String, optional: true
      },
    }
  end

  # Read back through JSON, so the runtime is handed the String-keyed Hashes a wire call carries — the literal
  # object sets above compare against exactly those.
  def nested_payloads
    [
      {}, { inner: nil }, { inner: {} }, { inner: { a: "x" } }, { inner: { a: 1 } },
      { inner: { a: "x", b: "y" } }, { inner: { a: "x", c: "z" } }, { inner: { c: "z" } },
      { inner: { a: "x", extra: "z" } }, { inner: [] }, { inner: [1] }, { inner: "s" }, { inner: 0 },
      # PRO-3441, discriminating the value-level collision rows above: one payload each side's OWN literal
      # set admits and the other's refuses, and a 5-key/2-key pair that only a wrong `minProperties`/
      # `maxProperties` reconciliation (`.max`/`.min` swapped) would tell apart.
      { inner: { b: 2 } }, { inner: { c: 3 } }, { inner: { a: "x", b: "y", c: "z", d: "w", e: "v" } }
    ].map { |payload| JSON.parse(JSON.generate(payload)) }
  end

  # `member`/`node` are each optional (PRO-3441): the collision walk below also needs the SIDE-ALONE
  # classes — the same node config or the same shape member, declared with nothing to collide against — so
  # a merged document can be compared to what either declaration means on its own.
  # The nested walk's class for a member x node row, declared once per run like a flat cell.
  def nested_cell(mname, nname, member, node)
    key = [:nested, mname, nname]
    return SchemaWireAudit.cells[key] if SchemaWireAudit.cells.key?(key)

    SchemaWireAudit.cells[key] = declare_nested(member, node)
  end

  def declare_nested(member, node, preprocess: nil)
    payload_opts = preprocess ? { type: Hash, preprocess: } : { type: Hash }
    Class.new do
      include Axn
      if member
        expects :payload, **payload_opts, &member
      else
        expects :payload, **payload_opts
      end
      class_eval(&node) if node
      def call = nil
    end
  rescue StandardError
    nil
  end

  # The three classes one collision row needs: both declarations together, and each alone. `nil` (not a
  # missing entry) when any of the three fails to build at all — a declaration only one side of the
  # collision can make (the guard rejects it standing alone too) has nothing here to compare.
  def declare_collision_trio(member, node)
    both = declare_nested(member, node)
    member_alone = declare_nested(member, nil)
    node_alone = declare_nested(nil, node)
    return nil if [both, member_alone, node_alone].any?(&:nil?)

    [both, member_alone, node_alone]
  end

  # Whether `prop`'s RECONCILED type is "object" — the same question `object_property?` asks of the
  # emitter's own merge, asked here from the outside (a spec may not reach into the emitter's private
  # methods) since it decides which rows the keyword inventory below can meaningfully compare: a
  # non-object collision takes the wholesale `allOf` branch, and everything that keyword-by-keyword
  # reconciliation could conflate simply doesn't run for it.
  def object_shaped_property?(prop)
    type = prop.is_a?(Hash) ? prop[:type] : nil
    type == "object" || (type.is_a?(Array) && type.include?("object"))
  end

  # The looseness direction over the nested walk, on the flat walk's terms: a payload the document accepts and
  # the runtime rejects must be explained by a residue the class reports.
  it "reports every nested value it accepts inbound that the runtime rejects" do
    checked = 0
    explained = 0
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        klass = nested_cell(mname, nname, member, node)
        next if klass.nil?
        next if unrepresentable_deep_drop?(klass)

        document = schemer(klass.input_schema)
        reported = residues_for(klass).any?
        nested_payloads.each do |payload|
          runtime_ok = begin
            klass.call(payload:).ok?
          rescue StandardError
            false
          end
          checked += 1
          next unless document.valid?(JSON.parse(JSON.generate("payload" => payload))) && !runtime_ok

          if reported
            explained += 1
            next
          end

          wrong << "#{mname} / #{nname}: document accepts #{payload.inspect}, runtime rejects it, and nothing " \
                   "is reported — schema #{klass.input_schema[:properties][:payload].inspect}"
        end
      end
    end

    expect(checked).to be > 150
    # The transforming and gated rows must actually REACH a residue: an explanation that never fires would make
    # them decorative.
    expect(explained).to be > 5
    expect(wrong).to be_empty, "these nested schemas accept what the runtime rejects without saying so:\n  #{wrong.join("\n  ")}"
  end

  # The never-stricter direction over the nested walk: a gated member or node is skipped on the calls its
  # condition closes, so the merged document must admit what the runtime admits then — including a payload
  # that omits the gated position altogether.
  it "never rejects inbound a nested value the runtime accepts" do
    accepted = 0
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        klass = nested_cell(mname, nname, member, node)
        next if klass.nil?
        next if unrepresentable_deep_drop?(klass)

        document = schemer(klass.input_schema)
        nested_payloads.each do |payload|
          runtime_ok = begin
            klass.call(payload:).ok?
          rescue StandardError
            false
          end
          next unless runtime_ok

          accepted += 1
          next if document.valid?(JSON.parse(JSON.generate("payload" => payload)))

          wrong << "#{mname} / #{nname}: runtime accepts #{payload.inspect}, document rejects it, " \
                   "schema #{klass.input_schema[:properties][:payload].inspect}"
        end
      end
    end

    expect(accepted).to be > 100
    expect(wrong).to be_empty, "these nested schemas reject what the runtime accepts:\n  #{wrong.join("\n  ")}"
  end

  # The same direction with the payload itself transformed: a Proc replacing every non-nil wire value with one the
  # contract accepts makes the runtime accept every payload, so the document must too — whatever the member's
  # shape and the nodes below state, all of it reads the Proc's output. The walk above cannot see this: with no
  # transform on the payload, the wire value is the checked one.
  it "never rejects inbound a nested value the runtime accepts once the payload is transformed" do
    accepted = 0
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        plain = nested_cell(mname, nname, member, node)
        next if plain.nil?

        repair = nested_payloads.find do |payload|
          plain.call(payload:).ok?
        rescue StandardError
          false
        end
        next if repair.nil?

        klass = declare_nested(member, node, preprocess: ->(v) { v.nil? ? v : repair })
        next if klass.nil?
        next if unrepresentable_deep_drop?(klass)

        document = schemer(klass.input_schema)
        nested_payloads.each do |payload|
          runtime_ok = begin
            klass.call(payload:).ok?
          rescue StandardError
            false
          end
          next unless runtime_ok

          accepted += 1
          next if document.valid?(JSON.parse(JSON.generate("payload" => payload)))

          wrong << "#{mname} / #{nname}: runtime accepts #{payload.inspect}, document rejects it, " \
                   "schema #{klass.input_schema[:properties][:payload].inspect}"
        end
      end
    end

    expect(accepted).to be > 100
    expect(wrong).to be_empty, "these transformed schemas reject what the runtime accepts:\n  #{wrong.join("\n  ")}"
  end

  # The satisfiability corollary over the NESTED walk. The flat example above asked it of one field, and
  # nothing asked it of a collision — which is exactly where it fails, because conjoining two declarations
  # is the operation that can empty a node. A gated member is the case: its checks are skipped on the calls
  # its condition closes, so the contract keeps accepting values that an unconditional `allOf` of both types
  # admits none of. That went unwatched through this whole PR; the flat product cannot reach it, since it
  # declares a single field and so has nothing to conjoin.
  it "never emits a nested node nothing satisfies for a contract something satisfies" do
    live = 0
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        klass = nested_cell(mname, nname, member, node)
        next if klass.nil?
        next if unrepresentable_deep_drop?(klass)

        accepted = nested_payloads.select do |payload|
          klass.call(payload:).ok?
        rescue StandardError
          false
        end
        next if accepted.empty? # nothing satisfies the contract either, so an empty node is faithful

        live += 1
        document = schemer(klass.input_schema)
        next if nested_payloads.any? { |payload| document.valid?(JSON.parse(JSON.generate("payload" => payload))) }

        wrong << "#{mname} / #{nname}: runtime accepts #{accepted.first.inspect}, document accepts nothing " \
                 "at all — #{klass.input_schema[:properties][:payload].inspect}"
      end
    end

    # Per ROW here, not per cell: the product is {member} x {node}, and a row counts once if any payload
    # satisfies its contract. Measured at 40.
    expect(live).to be > 30
    expect(wrong).to be_empty, "these nested contracts are satisfiable and their schemas are not:\n  #{wrong.join("\n  ")}"
  end

  # PRO-3441. Every example above asks whether the MERGED document agrees with the MERGED runtime — which
  # needs a validator collision someone thought to write, because that is what the runtime side of the
  # comparison is built from. This one needs nobody to have thought of anything.
  #
  # Each side of a collision is enforced UNCONDITIONALLY (PRO-3405: the runtime never lets one side simply
  # win), and each side's own document, declared ALONE, already agrees with that side's own runtime — that
  # is exactly what the flat and nested walks above spend their whole budget establishing. So a value the
  # runtime accepts through a collision is a value BOTH sides' own runtimes accept, which is a value BOTH
  # sides' own documents accept (declared alone). The contrapositive is the tripwire: whatever the MERGED
  # document accepts that a side declared ALONE refuses cannot be a value the collision's own runtime
  # accepts either — so if the merged document accepts it anyway, the merge is unsound, full stop, with no
  # dependency on which keyword or which validator did it. This is what would have named `:enum` (PRO-3405)
  # without anyone thinking of the case, and it is the corollary of the class of gap the map/subfield fix
  # elsewhere in this PR closes.
  #
  # Excluded, both taken from the emitter rather than re-derived (`unrepresentable_deep_drop?` above):
  # a residue means the emitted document ITSELF already admits it cannot state the full contract — a
  # transforming side stands down, and a merge reports what it declined to conjoin — so the merged document
  # may be looser than a side's own alone document by design, and says so.
  def collision_reports_a_residue?(klass) = residues_for(klass).any?

  it "never accepts merged what either colliding declaration would refuse alone" do
    audited = 0
    excluded = Hash.new(0)
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        trio = declare_collision_trio(member, node)
        next if trio.nil?

        both, member_alone, node_alone = trio
        next if unrepresentable_deep_drop?(both)

        if collision_reports_a_residue?(both)
          residues_for(both).each { |residue| excluded[residue.kind] += 1 }
          next
        end

        audited += 1
        merged_doc = schemer(both.input_schema)
        member_doc = schemer(member_alone.input_schema)
        node_doc = schemer(node_alone.input_schema)

        nested_payloads.each do |payload|
          doc_payload = JSON.parse(JSON.generate("payload" => payload))
          next unless merged_doc.valid?(doc_payload)
          next if member_doc.valid?(doc_payload) && node_doc.valid?(doc_payload)

          refuser = member_doc.valid?(doc_payload) ? "node" : "member"
          wrong << "#{mname} / #{nname}: merged document accepts #{payload.inspect}, #{refuser}-alone " \
                   "refuses it — merged #{both.input_schema.dig(:properties, :payload, :properties, :inner).inspect}"
        end
      end
    end

    # Both stand-down kinds must actually be reachable, or the exclusion above is decorative in one
    # direction: `:conditional` from the gated member/node rows, `:inherent` from the transforming ones.
    expect(excluded[:conditional]).to be > 0
    expect(excluded[:inherent]).to be > 0
    expect(audited).to be > 60
    expect(wrong).to be_empty, "these merges accept what a side declared alone refuses:\n  #{wrong.join("\n  ")}"
  end

  # PRO-3441. The keyword-agnostic check above proves SOUNDNESS; this one proves the corpus actually
  # EXERCISES the reconciliation it is meant to guard, so a keyword `merge_shape_member_property` stops
  # reconciling cannot silently drop out of the audit's reach — and that a keyword starting to collide is a
  # decision someone makes, not a diff nobody notices.
  #
  # Scoped to OBJECT-SHAPED collisions only (`object_shaped_property?` on both alone-sides): a non-object
  # collision (two scalars, a union) takes `combine_two`'s wholesale `allOf` branch instead, where nothing
  # is reconciled keyword-by-keyword at all — every value-level keyword differing there is EXPECTED and
  # already covered by the acceptance tripwire above (an `allOf` conjoins by construction, never drops).
  def reconciled_merge_keywords
    %i[type format properties required minProperties maxProperties additionalProperties propertyNames enum]
  end

  it "collides only on keywords merge_shape_member_property actually reconciles" do
    reconciled_seen = Hash.new(0)
    unexpected = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        trio = declare_collision_trio(member, node)
        next if trio.nil?

        _both, member_alone, node_alone = trio
        member_prop = member_alone.input_schema.dig(:properties, :payload, :properties, :inner) || {}
        node_prop = node_alone.input_schema.dig(:properties, :payload, :properties, :inner) || {}
        next unless object_shaped_property?(member_prop) && object_shaped_property?(node_prop)

        (member_prop.keys & node_prop.keys).each do |key|
          next if member_prop[key] == node_prop[key]

          if reconciled_merge_keywords.include?(key)
            reconciled_seen[key] += 1
          else
            unexpected << "#{mname} / #{nname}: #{key.inspect} collides (#{member_prop[key].inspect} vs " \
                          "#{node_prop[key].inspect}) and is not in reconciled_merge_keywords"
          end
        end
      end
    end

    # Every keyword the merge claims to reconcile must actually be EXERCISED by a real collision, or its
    # branch is dead code the corpus never reaches — `:format` is asserted only by absence (the merge
    # deletes it, so two colliding formats never both survive to compare) and is excluded from this floor
    # for that reason, not because it goes unreconciled.
    (reconciled_merge_keywords - [:format]).each do |key|
      expect(reconciled_seen[key]).to be > 0, "#{key.inspect} never actually collided in this corpus"
    end
    expect(unexpected).to be_empty, "these keywords collide without a reconciliation rule:\n  #{unexpected.join("\n  ")}"
  end

  # A record class with a finder that takes any token, so a `model:` field is declarable outside Rails: what
  # these rows measure is the wire key the model's id shares with another declaration, not the lookup.
  audit_record = Class.new do
    def self.fetch(id) = new(id)
    def initialize(id) = @id = id
  end
  define_method(:audit_record) { audit_record }

  # Declarations whose only refusal was that the emitted schema could not state them exactly. Each one is now
  # legal, so each is held to both inbound directions on its own terms: never refuse a value the runtime accepts,
  # and name everything accepted that the runtime refuses. Every row is a single declaration (or a `model:`
  # field and the one declaration claiming its id's wire key), so none of the merge walks above reaches it.
  #
  # `model:` routes use a finder that resolves any token, so the id's own type is never what rejects a call
  # here, and the one `id_type:` row that states a type keeps its payloads inside it (the model id's narrower
  # type is a stated exception to the exact core).
  def relaxed_declarations
    relaxed_model_id_declarations.merge(relaxed_method_read_declarations, relaxed_value_declarations, raw_array_shape_grid)
  end

  # Every raw `shape:` spelling a distributing `type: Array` (or a bag's `klass: Array`) can carry, at each position
  # it can be written: {field, raw member, `of:` bag} x {explicit `container:` Array / Hash / none}. A spelling a
  # guard refuses is skipped by the walk below; each that declares is held to both directions. Payloads cover a
  # member-bearing element, a wrong-typed member, a scalar element, a nested Array element and the empty Array.
  def raw_array_shape_grid
    sku = Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })
    values = [[{ sku: "a" }], [{ sku: 1 }], ["abc"], [[{ sku: 1 }]], []]
    { "container: Array" => Array, "container: Hash" => Hash, "no container:" => nil }.each_with_object({}) do |(cname, container), rows|
      shape = container ? { container:, members: [sku] } : { members: [sku] }
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Array }, shape: })
      rows["raw shape on a type: Array field, #{cname}"] = [proc { expects :x, type: Array, shape: }, values.map { |v| { x: v } }]
      rows["raw shape on a type: Array raw member, #{cname}"] =
        [proc { expects :o, type: Hash, shape: { members: [member] } }, values.map { |v| { o: { x: v } } }]
      rows["raw shape in a klass: Array bag, #{cname}"] =
        [proc { expects :x, type: Array, of: { klass: Array, shape: } }, values.map { |v| { x: [v] } }]
    end
  end

  def relaxed_model_id_declarations
    record = audit_record
    ids = [1, "s", nil, { detail: "x" }, { detail: 5 }, {}]
    in_payload = ids.map { |id| { payload: { company_id: id } } } + [{ payload: {} }]
    {
      "model id + ungated dotted claim" => [proc {
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
        expects :detail, on: "payload.company_id", type: String
      }, in_payload],
      "model id + gated dotted claim" => [proc {
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
        expects :detail, on: "payload.company_id", type: String, if: -> { false }
      }, in_payload],
      "model id + optional dotted claim" => [proc {
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
        expects :detail, on: "payload.company_id", type: String, optional: true
      }, in_payload],
      "model id + gated shape member with members" => [proc {
        expects :payload, type: Hash do
          field :company_id, type: Hash, if: -> { false } do
            field :detail, type: String
          end
        end
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
      }, in_payload],
      "model id + gated Hash shape member" => [proc {
        expects :payload, type: Hash do
          field :company_id, type: Hash, if: -> { false }
        end
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
      }, in_payload],
      "model id + ungated shape member with members" => [proc {
        expects :payload, type: Hash do
          field :company_id, type: Hash do
            field :detail, type: String
          end
        end
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
      }, in_payload],
      "model id + top-level sibling a subfield nests under" => [proc {
        expects :company, model: { klass: record, finder: :fetch }
        expects :company_id, type: Hash
        expects :detail, on: "company_id", type: String
      }, ids.map { |id| { company_id: id } }],
      # The same implicit key with no `model:` beside it: nothing beneath rejects a value that is not an object.
      "optional dotted subfield" => [proc {
        expects :payload, type: Hash
        expects :detail, on: "payload.company_id", type: String, optional: true
      }, in_payload],
      "id_type beside a differently typed sibling" => [proc {
        expects :company, model: { klass: record, finder: :fetch, id_type: Integer }
        expects :company_id, type: String
      }, [{ company_id: 1 }, { company_id: "a" }, { company_id: "" }]],
      "id_type with no JSON token type" => [proc {
        expects :company, model: { klass: record, finder: :fetch, id_type: Hash }
      }, [{ company_id: 1 }, { company_id: "a" }, { company_id: { a: 1 } }]],
      "id_type Float" => [proc {
        expects :company, model: { klass: record, finder: :fetch, id_type: Float }
      }, [{ company_id: 1 }, { company_id: 1.5 }]],
    }
  end

  # The same keys read with `method_call:`, which reads a method off whatever the key holds rather than settling
  # absent — alone, beside a `model:` id sharing the key, and beside a plain-key read that still wants an object.
  def relaxed_method_read_declarations
    record = audit_record
    in_payload = [1, "s", nil, { detail: "x" }, { detail: 5 }, {}].map { |id| { payload: { company_id: id } } } + [{ payload: {} }]
    {
      # A REQUIRED `method_call:` descendant reads a method off whatever the key holds, so it rejects no value for
      # not being an object — with or without a `model:` id sharing the key.
      "model id + required method_call dotted claim" => [proc {
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: record, finder: :fetch }
        expects :size, on: "payload.company_id", type: Integer, method_call: true
      }, in_payload + [{ payload: { company_id: "abc" } }, { payload: { company_id: [1, 2] } }]],
      "required method_call dotted subfield" => [proc {
        expects :payload, type: Hash
        expects :size, on: "payload.company_id", type: Integer, method_call: true
      }, in_payload + [{ payload: { company_id: "abc" } }, { payload: { company_id: [1, 2] } }]],
      # ...while a required plain-key read beside it still rejects a non-object.
      "required method_call beside a required key read" => [proc {
        expects :payload, type: Hash
        expects :detail, on: "payload.company_id", type: String
        expects :size, on: "payload.company_id", type: Integer, method_call: true
      }, in_payload + [{ payload: { company_id: "abc" } }, { payload: { company_id: { detail: "x", size: 2 } } }]],
      "optional method_call dotted subfield" => [proc {
        expects :payload, type: Hash
        expects :size, on: "payload.company_id", type: String, optional: true, method_call: true
      }, in_payload + [{ payload: { company_id: "abc" } }, { payload: { company_id: [1, 2] } }]],
    }
  end

  def relaxed_value_declarations
    sku = Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })
    {
      "inclusion only a tolerated blank can pass" => [proc {
        expects :n, type: Array, presence: false, inclusion: { in: ["a"], allow_blank: true }
      }, [[], [1], ["a"], nil].map { |n| { n: } }],
      # The same set on a union and in an `of:` bag, where the node states its types as `anyOf` branches.
      "inclusion only a tolerated blank can pass, on a union" => [proc {
        expects :n, type: [Array, String], presence: false, inclusion: { in: [1], allow_blank: true }
      }, [[], "", [1], "a", nil].map { |n| { n: } }],
      "inclusion only a tolerated blank can pass, on a two-container union" => [proc {
        expects :n, type: [Array, Hash], presence: false, inclusion: { in: [1], allow_blank: true }
      }, [[], {}, [1], { "a" => 1 }].map { |n| { n: } }],
      "inclusion only a tolerated blank can pass, on a union in an of: bag" => [proc {
        expects :n, type: Array, of: { klass: [Array, String], presence: false, inclusion: { in: [1], allow_blank: true } }
      }, [[[]], [""], [[1]], ["a"]].map { |n| { n: } }],
      # A nullable node keeps the set: `null` satisfies it. The tolerated non-nil blank it still refuses (`[]`) is
      # the stated blank-axis exception, so these rows leave that payload out and hold everything else.
      "inclusion on a nullable union a nil satisfies" => [proc {
        expects :n, type: [Array, NilClass], presence: false, inclusion: { in: [1], allow_blank: true }
      }, [nil, [1], ["a"], "a"].map { |n| { n: } }],
      "inclusion on a nil-tolerant Array a nil satisfies" => [proc {
        expects :n, type: Array, allow_nil: true, presence: false, inclusion: { in: [1], allow_blank: true }
      }, [nil, [1], ["a"]].map { |n| { n: } }],
      "of: klass Array with a shape" => [proc {
        expects :rows, type: Array, of: { klass: Array, shape: { members: [sku] } }
      }, [[[{ sku: "a" }]], [[{ sku: 1 }]], [[1]], [{ sku: "a" }], [[]]].map { |rows| { rows: } }],
      "type Array with a raw shape" => [proc {
        expects :rows, type: Array, shape: { members: [sku] }
      }, [[{ sku: "a" }], [{ sku: 1 }], [1], []].map { |rows| { rows: } }],
      "allow_empty false beside a per-call length floor" => [proc {
        expects :n, type: String, allow_empty: false, allow_nil: true, length: { minimum: ->(_record) { 2 } }
      }, ["", nil, "a", "ab"].map { |n| { n: } }],
      "of: on a union whose one container is Array" => [proc {
        expects :n, type: [Array, String], of: Integer
      }, [[1], ["a"], "s", 1, []].map { |n| { n: } }],
      "of: on a nilable Array union" => [proc {
        expects :n, type: [Array, NilClass], of: Integer
      }, [[1], ["a"], nil].map { |n| { n: } }],
      "allow_nil beside presence" => [proc {
        expects :n, type: String, allow_nil: true, presence: true
      }, [nil, "", "a"].map { |n| { n: } } + [{}]],
      "allow_blank beside presence that overrides it" => [proc {
        expects :n, type: String, allow_blank: true, presence: { allow_blank: false }
      }, [nil, "", "a"].map { |n| { n: } }],
      "allow_nil beside presence in an of: bag" => [proc {
        expects :n, type: Array, of: { klass: String, allow_nil: true, presence: true }
      }, [[nil], [""], ["a"]].map { |n| { n: } }],
      "allow_nil beside presence on a shape member" => [proc {
        expects :n, type: Hash do
          field :a, type: String, allow_nil: true, presence: true
        end
      }, [{ a: nil }, { a: "" }, { a: "x" }, {}].map { |n| { n: } }],
    }
  end

  it "holds each declaration a precision-only refusal used to turn away to both inbound directions" do
    stricter = []
    unreported = []
    checked = 0

    relaxed_declarations.each do |name, (declaration, payloads)|
      klass = begin
        Class.new do
          include Axn
          class_eval(&declaration)
          def call = nil
        end
      rescue ArgumentError
        next # a spelling a guard refuses has no document to hold to either direction
      end
      document = schemer(klass.input_schema)
      reported = residues_for(klass).any?

      payloads.each do |payload|
        runtime_ok = klass.call(**payload).ok?
        document_ok = document.valid?(JSON.parse(JSON.generate(payload)))
        checked += 1
        stricter << "#{name}: runtime accepts #{payload.inspect}, document rejects it — #{klass.input_schema.inspect}" if runtime_ok && !document_ok
        next unless document_ok && !runtime_ok && !reported

        unreported << "#{name}: document accepts #{payload.inspect}, runtime rejects it, and nothing is reported — " \
                      "#{klass.input_schema.inspect}"
      end
    end

    expect(checked).to be > 90
    expect(stricter).to be_empty, "these documents reject what the runtime accepts:\n  #{stricter.join("\n  ")}"
    expect(unreported).to be_empty, "these documents accept what the runtime rejects without saying so:\n  #{unreported.join("\n  ")}"
  end
end
