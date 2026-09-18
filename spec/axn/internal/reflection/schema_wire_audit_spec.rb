# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "json_schemer"
require "active_support/core_ext/object/blank"
require "bigdecimal"
require "date"
require "json"

# Reflection has one invariant it may never break, stated in `docs/reference/guards-and-projections.md`: the
# emitted document may say LESS than the contract inbound and MORE than it outbound, never the reverse. Every
# individual keyword is argued for in `schema_spec.rb`; nothing there asks the question this file asks, which is
# whether the document and the runtime agree when a REAL JSON Schema engine is the one reading it.
#
# So this walks the product of {declared type} x {validator spelling} x {tolerance} and, for every cell, asks
# `json_schemer` — not a re-derivation of JSON Schema, and not the emitter's own opinion of what it wrote:
#
#   * OUTBOUND, the schema must never REJECT a value the action exposed successfully. This is the sharp
#     direction: the action settled ok, axn serialized the value, and its own `output_schema` refuses it.
#   * INBOUND, the schema must never ACCEPT a value the runtime rejects, which is the looseness clients are
#     told they can rely on.
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
# under the wrong grammar. This file's own hard direction (inbound must never accept what the runtime
# refuses) is exactly what that mismatch would have violated had this file gone looking with the right tool.
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
    }
  end

  # `optional:` is axn's nil-AND-blank tolerance, which is why it earns a column of its own here.
  def tolerances = { "required" => {}, "optional" => { optional: true } }

  # Only values a JSON document can carry, since that is what both directions are about.
  # `"a\nb"` is here specifically for `format a-z` (PRO-3441): `^`/`$` are LINE anchors under Ruby's regex
  # engine and STRING anchors under ECMA-262, so a probe with no embedded newline could never have told the
  # two grammars apart — every other value here is a single line, and the pattern axis would have kept
  # passing by accident whichever engine `schemer` used.
  def probe_values = [nil, true, false, 0, 1, 2, 1.5, 123, "", "a", "abc", "1", "123", "a\nb", [], [1], {}, { "a" => 1 }]

  # A tolerated BLANK passes every validator — ActiveModel skips it before any of them runs — while the emitted
  # `enum`/`pattern`/narrowing still describes only the non-blank values. So a blank-tolerant position accepts
  # `""`, `[]`, `{}` and `false` at runtime and its document refuses them.
  #
  # This is PRO-3016's axis conflation surfacing in reflection, it predates the work this file was written for,
  # and closing it is a contract decision rather than a bug fix (PRO-3244: stand the keyword down, which is looser, or
  # widen the emitted set with the blank). Excluded by NAME so the residue below stays meaningful, and so that
  # deleting these two lines is all it takes to hold the emitter to it once that call is made.
  def known_blank_tolerance_divergence?(tolerance_name, value)
    tolerance_name == "optional" && !value.nil? && value.blank?
  end

  # The same class wearing its other face. A blank-tolerant `length:` means "blank OR exactly this size", and no
  # single keyword says that — so the emitter DROPS the floor to let the blank through, and the document then
  # accepts every shorter value as well (`type: String, length: { is: 3 }, optional: true` emits `maxLength: 3`
  # with no `minLength`, so `"a"` passes the document and fails the runtime). One root, two symptoms: outbound
  # the document refuses the blank it accepts, inbound it accepts the non-blanks the constraint refuses. The
  # honest spelling is an `anyOf` of the blank and the constrained form, which is the decision PRO-3244 carries.
  def floor_bearing_validators = ["length is:3"]

  def known_blank_tolerance_floor_drop?(tolerance_name, validator_name)
    tolerance_name == "optional" && floor_bearing_validators.include?(validator_name)
  end

  # A Ruby class the wire cannot carry a distinct form of: the runtime wants an INSTANCE and JSON has only its
  # shape. `type: Float` emits `"number"` and a JSON `0` is an Integer to Ruby; a Symbol, Time or BigDecimal is
  # reached only through a String or number that axn will refuse. Inbound-only, and inherent rather than
  # unfixed — there is no keyword that says "a number written with a decimal point".
  def no_distinct_wire_form = ["[Integer,Float]", "Numeric"]

  # Validators with no JSON Schema spelling on some BRANCH of the declared type, so the document says nothing
  # there while the runtime speaks. Expressibility is a per-branch question, which is why this reads the tokens
  # rather than the declaration: `format:`/`length:` measure `value.to_s` and so apply to every class, while
  # `pattern`/`minLength`/`maxLength` exist only for a string — so `type: [String, Integer], length: { is: 3 }`
  # constrains the Integer at runtime (`123.to_s.length`) and has no keyword to say so. A numeric bound is the
  # mirror: no keyword bounds a string. Both are inherent to JSON Schema rather than unfixed here.
  def numeric_bound_validators = ["num gt:0", "cmp gt:0", "cmp equal_to:1"]

  def inexpressible_inbound?(validator_name, tokens)
    return tokens.any? { |t| t != String } if ["length is:3", "format a-z"].include?(validator_name)
    return tokens.any? { |t| !numeric_token?(t) } if numeric_bound_validators.include?(validator_name)

    false
  end

  def numeric_token?(token) = token.is_a?(Module) && token <= Numeric

  # PRO-3245. A bare `numericality:` on a String position accepts a numeric string and rejects the rest,
  # and the document says nothing — so it accepts every string. The seam exists (`only_integer:` emits the exact
  # test via `merge_integer_literal_pattern`), but an EXACT pattern for bare numericality is hard: ActiveModel
  # funnels through `Kernel.Float`, which takes underscores (`Float("1_000")`) and surrounding whitespace, while
  # `is_hexadecimal_literal?` rejects hex. An approximation would be looser or stricter than the runtime, and
  # inbound looser is the direction reflection may never take.
  def known_unpatterned_numeric_string?(validator_name, tokens)
    validator_name == "numericality:true" && tokens.any? { |t| t == String }
  end

  # PRO-3246. `single_type_for` renders an UNKNOWN class as the permissive `"string"` — right for a
  # narrow custom value class, which serializes through `to_s`, and wrong for a token like `Object` or
  # `Comparable` that admits numbers and everything else besides. Two consequences, both pre-existing and both
  # rooted in that one fallback rather than in any validator:
  #
  #   inbound         the document says `"string"` where the runtime takes an Integer, so it accepts `"a"`
  #                   under a `numericality:` that rejects it
  #   satisfiability  the approximate `"string"` collides with a set of non-string literals — `type: Object,
  #                   inclusion: { in: [1, 2] }` emits `{type: "string", enum: [1, 2]}`, which nothing
  #                   satisfies, while the runtime accepts `1`
  #
  # Not cheap to close: the fallback is deliberate and load-bearing (`type: Object, length: 2..5` emits
  # `minLength` BECAUSE the node is a string), so it is the ticket's, not this file's.
  #
  # Scoped as narrowly as it can be. The satisfiability exclusion covers only the literal-projecting validator
  # that collides with the type; the NARROWING family on a broad token stays audited, because that is the class
  # this example was written for and the one that has regressed twice.
  def broad_token?(tokens)
    # Read through ancestry rather than `>=`, which would dispatch a comparison on a caller-supplied Module —
    # the same reason `string_reachable_key_token?` reads String's own ancestors in the emitter.
    tokens.any? { |t| t.is_a?(Module) && Numeric.ancestors.include?(t) && !t.ancestors.include?(Numeric) }
  end

  def known_broad_token_string_fallback?(validator_name, tokens)
    broad_token?(tokens) && validator_name.start_with?("incl ")
  end

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
      next if known_broad_token_string_fallback?(vname, Array(tklass))

      live += 1
      document = schemer(klass.input_schema)
      next if probe_values.any? { |value| document.valid?({ "n" => value }) }

      wrong << "#{tname} / #{vname} / #{tolname}: runtime accepts #{accepted.first.inspect}, document accepts " \
               "nothing at all — #{klass.input_schema[:properties][:n].inspect}"
    end

    expect(live).to be > 200
    expect(wrong).to be_empty, "these contracts are satisfiable and their schemas are not:\n  #{wrong.join("\n  ")}"
  end

  # The INBOUND direction: a document looser than the runtime tells a client a value is acceptable and then
  # rejects it on every call.
  it "never accepts inbound a value the runtime rejects" do
    wrong = []
    checked = 0

    each_cell do |tname, tklass, vname, vopts, tolname, tol|
      next if no_distinct_wire_form.include?(tname)

      tokens = Array(tklass)
      next if inexpressible_inbound?(vname, tokens)
      next if known_unpatterned_numeric_string?(vname, tokens)
      # Inbound, EVERY answer for a broad token rests on that same approximate `"string"`, so the whole row is
      # the fallback's rather than any validator's.
      next if broad_token?(tokens)
      next if known_blank_tolerance_floor_drop?(tolname, vname)

      klass = declare(:in, { type: tklass }.merge(vopts).merge(tol), nil)
      next if klass.nil?

      document = schemer(klass.input_schema)
      probe_values.each do |value|
        next if known_blank_tolerance_divergence?(tolname, value)

        runtime_ok = begin
          klass.call(n: value).ok?
        rescue StandardError
          false
        end
        checked += 1
        next unless document.valid?({ "n" => value }) && !runtime_ok

        wrong << "#{tname} / #{vname} / #{tolname}: document accepts #{value.inspect}, runtime rejects it, " \
                 "schema #{klass.input_schema[:properties][:n].inspect}"
      end
    end

    expect(checked).to be > 400
    expect(wrong).to be_empty, "these schemas accept what the runtime rejects:\n  #{wrong.join("\n  ")}"
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

  # The other excluded shape, asked of the emitter for the same reason: a declaration this document cannot
  # state in full REPORTS that, as a residue rendered into the relevant `description`. A transforming node
  # colliding with a member is the case — its keywords judge the coercion's target, and translating them
  # back to the wire form means inverting the transform, which reflection cannot do. So the emitter stands
  # down to the side that does describe the wire, and the position is knowingly looser than the runtime.
  #
  # Asking for the residue rather than re-deriving the condition is what keeps this from drifting: a row
  # excluded here is exactly a row the document admits it cannot describe, and one that stops reporting a
  # residue stops being excluded on the same commit.
  def residues_for(klass)
    residues = []
    Axn::Internal::Reflection::Schema.build_input_for(klass, residues:)
    residues
  end

  # Narrowed to `:inherent`/`:unfixed`, and the narrowing matters more than the exclusion. Written as "any
  # residue at all", this laundered every conditional stand-down out of the walk below — and since a
  # conditional stand-down is the one thing here that RELAXES a document, that hid the entire class of
  # inbound looseness it can cause. Six review rounds then had to find those cases by reading, in a file
  # whose whole purpose is to find them by measuring.
  #
  # A `:inherent` residue is different in kind from a `:conditional` one: nothing about it relaxes what
  # the document says relative to the wire form it can describe — it names a constraint on a value the
  # wire never carries, which no keyword could have expressed. `:unfixed` (PRO-3441 round 2, PR #285:
  # `NESTED_AXIS_RESIDUE`) DOES relax the document relative to the runtime — the emitter chose not to
  # duplicate a whole nested `values:` axis into every colliding property, to keep the document's size
  # bounded — but it is the SAME kind of thing this file's own exclusion doctrine already treats as
  # reported rather than hidden: a NAMED, ARGUED, declaration-time-visible trade, not a runtime-dependent
  # gate silently narrowing coverage. Its own residue message says explicitly what it declined to state,
  # which is exactly what lets `:unfixed` residues "shrink as they're closed" (the Residue kind's own
  # doc) rather than accumulate as blind spots — a `:conditional` residue offers no such argument and
  # stays excluded from THIS exclusion.
  def reported_residue_kinds = %i[inherent unfixed]

  def reported_inexpressible?(klass) = residues_for(klass).any? { |_path, residue| reported_residue_kinds.include?(residue.kind) }

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

  it "never accepts inbound a nested value the runtime rejects" do
    checked = 0
    reported = 0
    wrong = []

    nested_members.each do |mname, member|
      nested_nodes.each do |nname, node|
        klass = declare_nested(member, node)
        next if klass.nil?
        next if unrepresentable_deep_drop?(klass)

        if reported_inexpressible?(klass)
          reported += 1
          next
        end

        document = schemer(klass.input_schema)
        nested_payloads.each do |payload|
          runtime_ok = begin
            klass.call(payload:).ok?
          rescue StandardError
            false
          end
          checked += 1
          next unless document.valid?(JSON.parse(JSON.generate("payload" => payload))) && !runtime_ok

          wrong << "#{mname} / #{nname}: document accepts #{payload.inspect}, runtime rejects it, " \
                   "schema #{klass.input_schema[:properties][:payload].inspect}"
        end
      end
    end

    expect(checked).to be > 150
    # The transforming rows must actually REACH the stand-down: an exclusion that never fires would make
    # the rows above decorative, and a change that silently stopped emitting residues would pass this walk
    # by simply not having anything to exclude.
    expect(reported).to be > 5
    expect(wrong).to be_empty, "these nested schemas accept what the runtime rejects:\n  #{wrong.join("\n  ")}"
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
  # a residue means the emitted document ITSELF already admits it cannot state the full contract, and here
  # that includes every `:conditional` stand-down too, not only `reported_inexpressible?`'s `:inherent`
  # ones — a GATED side declared alone emits its full, unconditional property (nothing here closes its
  # gate), so the merged document is legitimately LOOSER than that side's own alone document by design, not
  # by defect. Verified: narrowing this exclusion to `:inherent` alone manufactures 8+ findings, every one a
  # gated row whose own residue already names the gap.
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
          residues_for(both).each { |path_and_residue| excluded[path_and_residue.last.kind] += 1 }
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
