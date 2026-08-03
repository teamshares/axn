# frozen_string_literal: true

# The collision rule reads the property names reflection EMITS, so "this declaration is rejected" and "the emitted
# schema names one property twice" are one fact rather than two that have to be kept in agreement. Every earlier
# design PREDICTED the emitted names instead, and every round of that design diverged from the emitter in one
# direction or the other: a claim where the schema emits nothing over-rejects a declaration the author is entitled
# to write, and a missing claim where it does emit lets two names collapse into one property silently.
#
# So the property worth asserting is not any single contract's verdict — those live in
# `property_name_collision_spec.rb` — but the EQUIVALENCE, over a battery chosen to include the contracts whose
# predicted and emitted property sets used to disagree: a per-validator-gated `type:` that `build_property` strips,
# a subtree `SubfieldTree` drops beneath a `model:` ancestor, an outbound type whose custom `as_json` leaves the
# property untyped, a scalar `of:` whose members are validated off an element that never becomes an object.
#
# Both directions are observable because the rule has a seam: with `reject_colliding_emitted_properties!` stubbed
# out, the same declaration builds the schema it would have emitted, and the collapse the rule refused is there to
# be read. Asserting the verdict alone cannot do this — a rejected contract has no schema to inspect, which is why
# a "rejected exactly when it collapses" check written over verdicts alone is satisfied by rejecting everything.
#
# Its own file rather than `property_name_collision_spec.rb`: the subject is the relationship between two layers
# over a whole battery, not the verdict on any one declaration, and that file is already three and a half thousand
# lines.
RSpec.describe "a collision verdict and the schema it is about" do
  def utf8_name = :café
  def latin1_name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

  # Every node in a reflected schema whose property names canonicalize onto one JSON property, at any depth. Reads
  # the schema the way `JSON.generate` will: an array's ELEMENT properties are their own node, and a multi-class
  # `type:`/`of:` reflects as alternative branches, each carrying properties of its own.
  def collapsed_nodes(props, path = [], out = [])
    return out unless props.is_a?(Hash)

    dupes = props.keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }.tally.select { |_key, n| n > 1 }.keys
    out << [path.join("."), dupes] unless dupes.empty?
    props.each do |key, prop|
      next unless prop.is_a?(Hash)

      child = path + [Axn::Reflection::Values.canonical_wire_key(key)]
      collapsed_nodes(prop[:properties], child, out)
      collapsed_nodes(prop.dig(:items, :properties), child + ["[]"], out)
      %i[anyOf allOf].each do |branch_key|
        [prop[branch_key], prop.dig(:items, branch_key)].each do |branches|
          next unless branches.is_a?(Array)

          branches.each_with_index do |branch, i|
            collapsed_nodes(branch[:properties], child + ["#{branch_key}[#{i}]"], out) if branch.is_a?(Hash)
          end
        end
      end
    end
    out
  end

  # Whether the rule refused this declaration.
  def rejected?(&declaration)
    build_axn(&declaration).then do |klass|
      klass.input_schema
      klass.output_schema
    end
    false
  rescue Axn::DuplicateFieldError
    true
  end

  # What each declaration EMITS with the rule stubbed out — the schemas the verdicts above are verdicts about.
  # Nothing else in the projection is touched, so a contract the rule accepts reads identically either way. The
  # stub is installed once for the whole batch rather than per declaration, because it cannot be uninstalled
  # inside an example: taking a verdict after one is in place would read the guard as absent.
  def collapses_without_the_rule(declarations)
    allow(Axn::Reflection::PropertyNames).to receive(:reject_colliding_emitted_properties!)
    declarations.transform_values do |declaration|
      klass = build_axn(&declaration)
      collapsed_nodes(klass.input_schema[:properties]) + collapsed_nodes(klass.output_schema[:properties])
    end
  end

  let(:widget) do
    Class.new do
      def self.name = "Widget"
      def self.find(_id) = new
    end
  end

  let(:cafe_data) { Data.define(:café) }

  let(:custom_as_json_data) do
    Data.define(:café) do
      def as_json(*) = { "totally" => "different" }
    end
  end

  # One entry per way the two layers have actually disagreed, plus a legal merge as the control in the other
  # direction. Declared as procs so each is class_eval'd into its own anonymous class.
  def contracts
    utf8 = utf8_name
    latin1 = latin1_name
    model = widget
    shaped = cafe_data
    untyped = custom_as_json_data
    member = ->(name, **validations) { Axn::Core::Contract::ShapeConfig.new(field: name, validations:) }

    {
      "plain colliding members" => proc {
        expects(:p, type: Hash) do
          field utf8, type: String
          field latin1, type: Integer
        end
      },
      "an of: element type's members beside a shape member" => proc {
        expects :list, type: Array, of: shaped,
                       shape: { members: [member.call(latin1, type: String)], container: Array }
      },
      "a subfield leaf beside a shape member of its parent" => proc {
        expects(:payload, type: Hash) { field utf8, type: String }
        expects latin1, on: :payload, optional: true
      },
      "a per-validator-gated type: on exposes" => proc {
        exposes :thing, type: { klass: shaped, if: -> { true } },
                        shape: { members: [member.call(latin1)], container: Hash }
      },
      "a subtree dropped beneath a model: ancestor" => proc {
        expects :rec, model:, optional: true
        expects :mid, on: :rec, type: Hash, optional: true, method_call: true
        expects utf8, on: "rec.mid", optional: true
        expects latin1, on: :mid, optional: true
      },
      "an outbound type whose custom as_json leaves the property untyped" => proc {
        exposes(:thing, type: untyped) { field latin1, type: String }
      },
      "a scalar of: whose members never become properties" => proc {
        expects :list, type: Array, of: String,
                       shape: { members: [member.call(utf8), member.call(latin1)], container: Array }
      },
      "the legal merge: a member and a same-named subfield" => proc {
        expects(:payload, type: Hash) { field utf8, type: String }
        expects utf8, on: :payload, optional: true
      },
      # A claim space belongs to a NODE, so one property name at two different nodes is two properties. Without
      # this the battery cannot see a guard that keeps one claim space for the whole schema, which rejects the
      # commonest shape a nested contract takes.
      "the legal repeat: one leaf name under two different parents" => proc {
        expects :from, type: Hash
        expects :to, type: Hash
        expects utf8, on: :from, as: :from_leaf, optional: true
        expects utf8, on: :to, as: :to_leaf, optional: true
      },
    }
  end

  it "is rejected exactly when the schema it would emit collapses" do
    declarations = contracts
    verdicts = declarations.transform_values { |declaration| rejected?(&declaration) }
    collapses = collapses_without_the_rule(declarations)

    disagreed = declarations.keys.filter_map do |label|
      [label, { rejected: verdicts[label], collapses: collapses[label] }] unless verdicts[label] == !collapses[label].empty?
    end

    expect(disagreed).to be_empty
  end

  # The two halves, stated on their own so a failure names which direction broke. Over-rejection first, because it
  # is the one an equivalence written over verdicts alone cannot see: refusing every contract in the battery
  # satisfies "rejected whenever it collapses" and breaks exactly this.
  it "accepts each contract whose emitted schema names every property once" do
    accepted = contracts.reject { |_label, declaration| rejected?(&declaration) }

    expect(accepted.keys).to eq(["a per-validator-gated type: on exposes",
                                 "a subtree dropped beneath a model: ancestor",
                                 "an outbound type whose custom as_json leaves the property untyped",
                                 "a scalar of: whose members never become properties",
                                 "the legal merge: a member and a same-named subfield",
                                 "the legal repeat: one leaf name under two different parents"])
  end

  it "rejects each contract whose emitted schema would name one property twice" do
    rejected = contracts.select { |_label, declaration| rejected?(&declaration) }

    expect(rejected.keys).to eq(["plain colliding members",
                                 "an of: element type's members beside a shape member",
                                 "a subfield leaf beside a shape member of its parent"])
  end
end
