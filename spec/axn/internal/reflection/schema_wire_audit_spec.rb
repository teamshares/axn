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
end

RSpec.describe "the emitted schema against runtime truth", :slow do
  # Deliberately not `build_axn`: this needs the class object itself for its schemas, and a fresh one per cell.
  def declare(direction, decl, value)
    Class.new do
      include Axn
      direction == :in ? expects(:n, **decl) : exposes(:n, **decl)
      define_method(:call) { direction == :in ? nil : expose(:n, value) }
    end
  rescue StandardError
    nil # a declaration a guard refuses has no schema to audit; the guards have their own product spec
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
      "format without" => { format: { without: /\d/ } },
      "exclusion [a]" => { exclusion: { in: %w[a] } },
      "absence" => { presence: false, absence: true },
      # Checks no keyword states at all: an accepted-value set, equality with a companion field, a callable, and
      # the numeric options with no bound to write.
      "acceptance" => { acceptance: true },
      "confirmation" => { confirmation: true },
      "validate" => { validate: ->(value) { "is one" if value == 1 } },
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
  def probe_values
    [nil, true, false, 0, 1, 2, 1.5, 123, "", "a", "abc", "abcd", "1", "123", "a\nb", [], [1], [1, 2, 3], [1, 2, 3, 4],
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

        klass = declare(:out, { type: tklass }.merge(vopts).merge(tol), value)
        next if klass.nil?

        result = begin
          klass.call
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
      klass = declare(:in, { type: tklass }.merge(vopts).merge(tol), nil)
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

        klass = declare(:in, gate.call({ type: tklass }.merge(vopts)).merge(tol), nil)
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
        klass = declare(:in, { type: tklass }.merge(validators.fetch(vname)), nil)
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

        klass = declare(:in, gate.call({ type: tklass }.merge(vopts)).merge(tol), nil)
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
          klass = declare(:in, wrap_decl.call({ klass: tklass }.merge(vopts)), nil)
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
      "literal object member" => proc { field :inner, type: Hash, inclusion: { in: [{ b: 2 }] } },
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
      # PRO-3441. The mirror of the four member-side rows above, so a value-level collision actually
      # arises: two `inclusion:` sets (the exact PRO-3405 shape), two SAME-keyword size bounds (so
      # `minProperties`/`maxProperties` COLLIDE rather than merely appear on one side), and two `of:` axes
      # naming DIFFERENT value/key types.
      "literal node" => proc { expects :inner, on: :payload, type: Hash, inclusion: { in: [{ c: 3 }] } },
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

  def nested_payloads
    [
      {}, { inner: nil }, { inner: {} }, { inner: { a: "x" } }, { inner: { a: 1 } },
      { inner: { a: "x", b: "y" } }, { inner: { a: "x", c: "z" } }, { inner: { c: "z" } },
      { inner: { a: "x", extra: "z" } }, { inner: [] }, { inner: [1] }, { inner: "s" }, { inner: 0 },
      # PRO-3441, discriminating the value-level collision rows above: one payload each side's OWN literal
      # set admits and the other's refuses, and a 5-key/2-key pair that only a wrong `minProperties`/
      # `maxProperties` reconciliation (`.max`/`.min` swapped) would tell apart.
      { inner: { b: 2 } }, { inner: { c: 3 } }, { inner: { a: "x", b: "y", c: "z", d: "w", e: "v" } }
    ]
  end

  # `member`/`node` are each optional (PRO-3441): the collision walk below also needs the SIDE-ALONE
  # classes — the same node config or the same shape member, declared with nothing to collide against — so
  # a merged document can be compared to what either declaration means on its own.
  def declare_nested(member, node)
    Class.new do
      include Axn
      if member
        expects :payload, type: Hash, &member
      else
        expects :payload, type: Hash
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
        klass = declare_nested(member, node)
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
        klass = declare_nested(member, node)
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
        klass = declare_nested(member, node)
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
end
