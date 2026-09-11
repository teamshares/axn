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
# `json_schemer` has one blind spot worth naming, since it makes this file weaker than it looks in exactly one
# place: it compiles `pattern` with RUBY's regex engine, where a real consumer uses ECMA-262. So the pattern
# TRANSLATION cannot be audited here and is covered by its own unit specs; what is audited is whether a pattern
# is emitted at a position whose values cannot satisfy it.
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
  def probe_values = [nil, true, false, 0, 1, 2, 1.5, 123, "", "a", "abc", "1", "123", [], [1], {}, { "a" => 1 }]

  # A tolerated BLANK passes every validator — ActiveModel skips it before any of them runs — while the emitted
  # `enum`/`pattern`/narrowing still describes only the non-blank values. So a blank-tolerant position accepts
  # `""`, `[]`, `{}` and `false` at runtime and its document refuses them.
  #
  # This is PRO-3016's axis conflation surfacing in reflection, it predates the work this file was written for,
  # and closing it is a contract decision rather than a bug fix (PRO-3240: stand the keyword down, which is looser, or
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
  # honest spelling is an `anyOf` of the blank and the constrained form, which is the decision PRO-3240 carries.
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

  # PRO-3240 item 3. A bare `numericality:` on a String position accepts a numeric string and rejects the rest,
  # and the document says nothing — so it accepts every string. The seam exists (`only_integer:` emits the exact
  # test via `merge_integer_literal_pattern`), but an EXACT pattern for bare numericality is hard: ActiveModel
  # funnels through `Kernel.Float`, which takes underscores (`Float("1_000")`) and surrounding whitespace, while
  # `is_hexadecimal_literal?` rejects hex. An approximation would be looser or stricter than the runtime, and
  # inbound looser is the direction reflection may never take.
  def known_unpatterned_numeric_string?(validator_name, tokens)
    validator_name == "numericality:true" && tokens.any? { |t| t == String }
  end

  # PRO-3240 item 4. `single_type_for` renders an UNKNOWN class as the permissive `"string"` — right for a
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
    JSONSchemer.schema(JSON.parse(JSON.generate(schema)))
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

  def nested_members
    {
      "object member" => proc { field :inner, type: Hash },
      "object member with a required String" => proc { field(:inner, type: Hash) { field :a, type: String } },
      "object member with a required Integer" => proc { field(:inner, type: Hash) { field :a, type: Integer } },
      "nil-tolerant object member" => proc { field(:inner, type: Hash, allow_nil: true) { field :a, type: String } },
      "map member" => proc { field :inner, type: Hash, of: { keys: { klass: Symbol }, values: { klass: String } } },
      "mixed-union member" => proc { field :inner, type: [Hash, Array] },
      "scalar member" => proc { field :inner, type: String },
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
    }
  end

  def nested_payloads
    [
      {}, { inner: nil }, { inner: {} }, { inner: { a: "x" } }, { inner: { a: 1 } },
      { inner: { a: "x", b: "y" } }, { inner: { a: "x", c: "z" } }, { inner: { c: "z" } },
      { inner: { a: "x", extra: "z" } }, { inner: [] }, { inner: [1] }, { inner: "s" }, { inner: 0 }
    ]
  end

  def declare_nested(member, node)
    Class.new do
      include Axn
      expects :payload, type: Hash, &member
      class_eval(&node)
      def call = nil
    end
  rescue StandardError
    nil
  end

  it "never accepts inbound a nested value the runtime rejects" do
    checked = 0
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
          checked += 1
          next unless document.valid?(JSON.parse(JSON.generate("payload" => payload))) && !runtime_ok

          wrong << "#{mname} / #{nname}: document accepts #{payload.inspect}, runtime rejects it, " \
                   "schema #{klass.input_schema[:properties][:payload].inspect}"
        end
      end
    end

    expect(checked).to be > 150
    expect(wrong).to be_empty, "these nested schemas accept what the runtime rejects:\n  #{wrong.join("\n  ")}"
  end
end
