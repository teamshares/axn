# frozen_string_literal: true

# An option bag is axn's own grammar — `klass:`, `in:`, `with:`, `minimum:` — and every consumer reads it with
# Symbols, axn's validators and ActiveModel's alike. A bag keyed by Strings (what a params-derived Hash or
# `.with_indifferent_access` produces) therefore answered nobody, and failed in the worst available way: the
# declaration succeeded and the field then rejected the values it had been declared to accept.
#
# Each example is written against a plain String-keyed Hash — the general defect — and the indifferent-access
# form a Rails author actually hands in is covered beside it, since axn's own copy turns one into the other.
RSpec.describe "option bag keys" do
  def string_keyed(hash) = hash.transform_keys(&:to_s)

  describe "a String-keyed bag validates exactly as the Symbol-keyed one does" do
    # The bag is built OUTSIDE the declaration block, which `build_axn` class_evals — the local is what the
    # declaration closes over.
    it "type:" do
      bag = string_keyed(klass: String)
      klass = build_axn { expects :a, type: bag }

      expect(klass.call(a: "x")).to be_ok
      expect(klass.call(a: 1)).not_to be_ok
    end

    it "of:" do
      bag = string_keyed(klass: String)
      klass = build_axn { expects :list, type: Array, of: bag }

      expect(klass.call(list: %w[x])).to be_ok
      expect(klass.call(list: [1])).not_to be_ok
    end

    it "inclusion:" do
      bag = string_keyed(in: %w[a b])
      klass = build_axn { expects :choice, inclusion: bag }

      expect(klass.call(choice: "a")).to be_ok
      expect(klass.call(choice: "z")).not_to be_ok
    end

    it "validate:" do
      bag = string_keyed(with: ->(value) { "bad" if value == 1 })
      klass = build_axn { expects :n, validate: bag }

      expect(klass.call(n: 2)).to be_ok
      expect(klass.call(n: 1)).not_to be_ok
    end

    # `model:` was the sharpest of the family: with the bag unread, the class was inferred from the field name,
    # so the lookup went to a constant the author never named.
    it "model:" do
      record = Struct.new(:id) { def self.find(id) = new(id) }
      bag = string_keyed(klass: record)
      klass = build_axn { expects :thing, model: bag }

      expect(klass.call(thing_id: 7)).to be_ok
    end

    # Not only axn's own validators: an ActiveModel bag is read the same way and was broken the same way.
    it "length:" do
      bag = string_keyed(minimum: 3)
      klass = build_axn { expects :s, length: bag }

      expect(klass.call(s: "abcd")).to be_ok
      expect(klass.call(s: "a")).not_to be_ok
    end

    it "the indifferent-access form a Rails author hands in" do
      klass = build_axn { expects :choice, inclusion: { in: %w[a b] }.with_indifferent_access }

      expect(klass.call(choice: "a")).to be_ok
      expect(klass.call(choice: "z")).not_to be_ok
    end
  end

  # Keys are canonicalized; values are not touched at all. Frozen, which is what a container answering
  # membership with its OWN `include?` must be to be stored at all (see `Contract#_detached_option_array`) — and
  # a frozen one is stored as the caller's object, so this asserts the identity directly.
  it "leaves an option's value the caller's own object" do
    values = Class.new(Array) { def include?(_value) = true }.new.push("a", "b").freeze
    bag = string_keyed(in: values)
    klass = build_axn { expects :choice, inclusion: bag }

    expect(klass.internal_field_configs.first.validations.dig(:inclusion, :in)).to be(values)
    expect(klass.call(choice: "z")).to be_ok
  end

  it "changes nothing for a bag that is already Symbol-keyed" do
    klass = build_axn { expects :choice, inclusion: { in: %w[a b] } }

    expect(klass.call(choice: "a")).to be_ok
    expect(klass.call(choice: "z")).not_to be_ok
    expect(klass.input_schema.dig(:properties, :choice, :enum)).to eq(%w[a b])
  end

  # Canonicalizing must not mask the rejection that already governs unrecognized keys — which is at the
  # DECLARATION level, above the bag, and still decides first.
  it "still rejects an unrecognized key in the declaration itself" do
    expect { build_axn { expects :a, "type" => String } }
      .to raise_error(ArgumentError, /Unknown key\(s\) "type" in field declaration/)
  end

  # An unrecognized key INSIDE a bag has never been rejected (there is no per-bag grammar to reject it
  # against), and canonicalizing it changes nothing: it is as inert as a Symbol key nothing reads.
  it "leaves an unrecognized key inside a bag as inert as its Symbol spelling" do
    stringy = build_axn { expects :choice, inclusion: { "in" => %w[a b], "bogus" => 1 } }
    symbolic = build_axn { expects :choice, inclusion: { in: %w[a b], bogus: 1 } }

    expect([stringy.call(choice: "a").ok?, stringy.call(choice: "z").ok?]).to eq([true, false])
    expect([symbolic.call(choice: "a").ok?, symbolic.call(choice: "z").ok?]).to eq([true, false])
  end

  # One option cannot hold two values, so the ambiguity is reported rather than resolved by whichever spelling
  # happened to be written last.
  it "rejects a bag declaring one option under both spellings" do
    expect { build_axn { expects :choice, inclusion: { "in" => %w[a b], :in => %w[c] } } }
      .to raise_error(ArgumentError, /the `inclusion:` option bag declares :in twice.*Declare the option once/m)
  end

  # A raw `shape:` member bypasses `expects`' option handling entirely, and the copy taken at declaration turns
  # an indifferent-access Hash into a plain one — so a member declared this way validated nothing at all.
  describe "a shape member's own grammar" do
    def member(validations) = Axn::Core::Contract::ShapeConfig.new(field: :a, validations:)

    def declared_with(member)
      build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
    end

    it "canonicalizes both levels of a String-keyed member" do
      klass = declared_with(member(string_keyed(type: string_keyed(klass: String))))

      expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({ a: { type: "string" } })
      expect(klass.call(payload: { a: "x" })).to be_ok
      expect(klass.call(payload: { a: 1 })).not_to be_ok
    end

    it "canonicalizes the indifferent-access form" do
      klass = declared_with(member({ type: { klass: String } }.with_indifferent_access))

      expect(klass.call(payload: { a: "x" })).to be_ok
      expect(klass.call(payload: { a: 1 })).not_to be_ok
    end

    # `ShapeConfig#description` is `metadata[:description]`, so String-keyed metadata lost every entry.
    it "canonicalizes a member's metadata too" do
      klass = declared_with(Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {},
                                                                 metadata: string_keyed(description: "the a")))

      expect(klass.input_schema.dig(:properties, :payload, :properties, :a, :description)).to eq("the a")
    end

    it "rejects a member declaring one option under both spellings" do
      expect { declared_with(member({ "type" => { klass: String }, :type => { klass: Integer } })) }
        .to raise_error(ArgumentError, /the validations of shape member `a` declares :type twice/)
    end
  end
end
