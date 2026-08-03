# frozen_string_literal: true

# What the declaration-time property-name rules deliberately do NOT promise. Each example here records a boundary
# rather than a guarantee, and each is recorded because the alternative was rejected on its merits — so a later
# change that closes one is a decision to make, not a bug to fix, and a change that WIDENS one has something here
# to fail against.
#
# All three come from the same place: a property name is a caller-supplied object, and three different layers ask
# it three different questions (the rules canonicalize it, the size budget counts it, the emitter merges on it).
# The rules refuse to run a name's own code, which is what keeps a verdict from being replaced by the name's
# exception — but refusing to run it is also what leaves these three answers approximate.
#
# Its own file rather than `property_name_collision_spec.rb`: an example that fails when a limitation is CLOSED
# reads as a regression wherever the guarantees live, and that file is already three and a half thousand lines.
RSpec.describe "the property-name rules' recorded residues" do
  def assigned(*fields, direction: :input)
    klass = build_axn { nil }
    configs = fields.each_with_index.map do |field, index|
      Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
    end
    klass.public_send(direction == :input ? :internal_field_configs= : :external_field_configs=, configs.freeze)
    klass
  end

  # The size budget's trie is IDENTITY-keyed, because a count may not ask a name its own `hash`/`eql?` — that
  # dispatch is the emitter's merge rule, and a guard that borrowed it would let the name decide how much of the
  # budget it spends. The emitter's `properties[config.field] =` IS a plain Hash, so two byte-equal Strings are one
  # property there and two nodes here: a contract naming exactly one property is charged for two.
  #
  # That is an OVER-count — the direction that rejects a legal declaration — so it is worth being explicit that
  # both halves are needed for it to bite, and neither is reachable by declaring anything. String field NAMES
  # require a config assigned onto a class (the DSL symbolizes every declared name and dotted route), and the
  # over-count is one per duplicate, so it only crosses the cap for a contract already at it.
  describe "the size budget counts byte-equal String names separately" do
    def duplicated_string_names(count)
      assigned(*Array.new(count) { "dup".dup })
    end

    it "charges byte-equal assigned String names as one property each" do
      expect { duplicated_string_names(25_001).input_schema }
        .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
    end

    # Why the example above asserts a verdict rather than a projection: below the cap nothing can see the
    # difference. The emitted schema is the one property the names actually name, whichever way they were counted.
    it "emits the one property they name, so nothing below the cap is affected" do
      properties = duplicated_string_names(3).input_schema[:properties]

      expect(properties.size).to eq(1)
      expect(properties.keys.map { |key| String.new(key) }).to eq(["dup"])
    end

    # The control that keeps the residue narrow: the same two names DECLARED are refused as the duplicate they
    # are, long before any count, so no author can reach the over-count by writing a contract.
    it "cannot be reached by declaring the same name twice" do
      expect do
        build_axn do
          expects "dup", optional: true
          expects "dup".dup, optional: true
        end
      end
        .to raise_error(Axn::DuplicateFieldError, /Duplicate field\(s\) declared: dup/)
    end
  end

  # `Reflection::Schema` is deliberately NOT one of the layers that refuse to dispatch (see AGENTS.md): its
  # `properties[config.field] =` is the merge rule, so one Hash key means "two declarations, one property, legal".
  # A name whose `eql?` raises therefore has no property map at all, and the emitter says so — exactly as a value
  # whose `to_s` raises cannot be rendered.
  #
  # What must NOT happen is a guard pre-empting that with a second merge decision of its own, which is a verdict
  # the name's own code would then be deciding. So the residue and the guarantee sit side by side here.
  describe "a name whose eql? raises" do
    let(:raising_eql) do
      Class.new(String) do
        def eql?(_other) = raise(NotImplementedError, "hijacked from #eql?")
      end
    end

    # Alone, such a name projects: nothing on the way to the schema asks it, and the emitter's own Hash has no
    # second key to compare it against. This is what makes the example below a statement about the emitter rather
    # than about "a raising eql? breaks projection" — a rule that asked the question would break this one.
    it "still projects when there is nothing for the emitter to merge it against" do
      klass = assigned(raising_eql.new("dup"))

      expect(klass.input_schema[:properties].keys.map { |key| String.new(key) }).to eq(["dup"])
    end

    it "surfaces from the emitter's merge once there is a second name" do
      klass = assigned(raising_eql.new("dup"), raising_eql.new("dup"))

      expect { klass.input_schema }.to raise_error(NotImplementedError, "hijacked from #eql?")
    end

    # The size budget runs BEFORE the build and decides which config the emitter would have built a shared wire
    # key's property from — the same question, asked earlier — and answers it without asking the name.
    it "is not asked that question by the size budget, which runs first" do
      configs = [raising_eql.new("dup"), raising_eql.new("dup")].each_with_index.map do |field, index|
        Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
      end

      %i[input output].each do |direction|
        expect { Axn::Internal::Reflection::PropertyNames.send(:reject_oversized_schema!, configs, [], for_output: direction == :output) }
          .not_to raise_error
      end
    end
  end

  # A shape member's name is canonicalized to a Symbol twice — the declaration walk judges what the first
  # conversion returned, and `ShapeConfig` converts that answer again on the way into the snapshot. For every name
  # Ruby's own contract covers those are the same object, because `to_sym` returns a Symbol and a Symbol's `to_sym`
  # is itself. A `to_sym` answering with a STRING breaks that contract, so the judged value and the stored key can
  # differ — the shape every other name defect this suite covers takes.
  #
  # It stays a residue rather than earning code because it is categorically unlike the reachable siblings that did
  # (a non-idempotent `to_s`, unrenderable bytes, a name owning its rendering, a raising `eql?`): each of those is
  # produced by an `ActiveSupport::SafeBuffer`-shaped value or by binary bytes read off a file, with nobody
  # intending harm. A `to_sym` that returns a String is a broken method, not an unusual object.
  describe "a member name whose to_sym answers with a String" do
    # Two conversions deep: the outer name's `to_sym` hands back another String subclass, whose own `to_sym` would
    # collapse every such name onto one Symbol.
    let(:non_symbol_to_sym) do
      inner = Class.new(String) { def to_sym = :collapsed }
      Class.new(String) { define_method(:to_sym) { inner.new("#{self}-mid") } }
    end

    def members_named(*names)
      members = names.map { |name| Axn::Core::Contract::ShapeConfig.new(field: name, validations: {}) }
      build_axn { expects :p, type: Hash, shape: { members:, container: Hash } }
    end

    # The collapse such a name might be expected to cause does not happen: both arrangements are refused at
    # declaration, so the residue is confusing prose rather than a contract that declares wrong.
    it "is refused rather than collapsed, even for byte-distinct names" do
      expect { members_named(non_symbol_to_sym.new("a"), non_symbol_to_sym.new("b")) }
        .to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared/)
    end

    # ...and this is the residue itself: the message names the INTERMEDIATE the first conversion returned, which
    # is not the key the snapshot stores and not a name the author wrote.
    it "reports the intermediate its to_sym returned rather than the name declared" do
      expect { members_named(non_symbol_to_sym.new("a"), non_symbol_to_sym.new("b")) }
        .to raise_error(Axn::DuplicateFieldError, /"a-mid"|"b-mid"/)
    end

    it "stores the intermediate as the member's name, not the Symbol a further conversion would give" do
      member = Axn::Core::Contract::ShapeConfig.new(field: non_symbol_to_sym.new("a"), validations: {})

      expect(member.field).to eq("a-mid")
      expect(member.field).not_to be_a(Symbol)
    end
  end
end
