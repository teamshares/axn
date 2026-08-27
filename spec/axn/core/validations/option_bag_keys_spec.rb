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
  # membership with its OWN `include?` must be to be stored at all (see `Internal::ShapeGraph.detached_option_array`) — and
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

  # An INNER contract is the one thing below a bag that is still axn's own grammar rather than caller data: the
  # same `klass:`/`of:`/`shape:`/`message:` bag, written at an Array's element, at a map's `keys:` axis, and at
  # its `values:` axis. The field-level pass canonicalizes one rung and stopped there, so the identical bag
  # DECLARED at the first rung and was REFUSED at the second — `of: { "klass" => String }` stored
  # `{ klass: String, container: Array }` while `of: { klass: Array, of: { "klass" => Integer } }` raised
  # `of: does not support "klass"`. One spelling, one meaning, every position.
  describe "an inner contract's own grammar" do
    it "canonicalizes an element bag one rung down" do
      inner = string_keyed(klass: Integer)
      klass = build_axn { expects :m, type: Array, of: { klass: Array, of: inner } }

      expect(klass.call(m: [[1]])).to be_ok
      expect(klass.call(m: [["x"]])).not_to be_ok
      expect(klass.input_schema.dig(:properties, :m, :items, :items)).to eq(type: "integer")
    end

    it "canonicalizes an element bag two rungs down" do
      inner = { klass: Array, of: string_keyed(klass: Integer) }
      klass = build_axn { expects :m, type: Array, of: { klass: Array, of: inner } }

      expect(klass.call(m: [[[1]]])).to be_ok
      expect(klass.call(m: [[["x"]]])).not_to be_ok
    end

    it "canonicalizes the indifferent-access form a Rails author hands in" do
      klass = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Integer }.with_indifferent_access } }

      expect(klass.call(m: [[1]])).to be_ok
      expect(klass.call(m: [["x"]])).not_to be_ok
    end

    it "canonicalizes a map's values: axis bag" do
      axis = string_keyed(klass: Integer)
      klass = build_axn { expects :m, type: Hash, of: { values: axis } }

      expect(klass.call(m: { a: 1 })).to be_ok
      expect(klass.call(m: { a: "x" })).not_to be_ok
    end

    it "canonicalizes a map's keys: axis bag" do
      axis = string_keyed(klass: Symbol)
      klass = build_axn { expects :m, type: Hash, of: { keys: axis, values: Integer } }

      expect(klass.call(m: { a: 1 })).to be_ok
      expect(klass.call(m: { "a" => 1 })).not_to be_ok
    end

    it "canonicalizes an indifferent-access axis bag" do
      klass = build_axn { expects :m, type: Hash, of: { values: { klass: Integer }.with_indifferent_access } }

      expect(klass.call(m: { a: 1 })).to be_ok
      expect(klass.call(m: { a: "x" })).not_to be_ok
    end

    # The MAP bag itself — the one naming the axes — is a third spelling of the same position, reached only one
    # rung down (a field's own is canonicalized by the field pass).
    it "canonicalizes a nested map bag's own axis names" do
      map = string_keyed(values: Integer)
      klass = build_axn { expects :m, type: Array, of: { klass: Hash, of: map } }

      expect(klass.call(m: [{ a: 1 }])).to be_ok
      expect(klass.call(m: [{ a: "x" }])).not_to be_ok
    end

    # An axis bag's OWN inner contract: the position furthest from the field pass, and the one a fix applied at
    # only the element edge would still leave refused.
    it "canonicalizes a bag nested inside an axis bag" do
      inner = string_keyed(klass: Integer)
      klass = build_axn { expects :m, type: Hash, of: { values: { klass: Array, of: inner } } }

      expect(klass.call(m: { a: [1] })).to be_ok
      expect(klass.call(m: { a: ["x"] })).not_to be_ok
    end

    # Canonicalizing keys must not disarm the grammar those keys are held to — every guard below reads the bag
    # by Symbol, and each one had a String spelling that reached it for the first time here.
    describe "the grammar the canonical bag is then held to" do
      it "still refuses an unrecognized key, naming its canonical spelling" do
        inner = string_keyed(klass: Integer, bogus: 1)

        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: inner } } }
          .to raise_error(ArgumentError, /of: does not support bogus:/)
      end

      it "still refuses an unrecognized key on an axis" do
        axis = string_keyed(klass: Integer, bogus: 1)

        expect { build_axn { expects :m, type: Hash, of: { values: axis } } }
          .to raise_error(ArgumentError, /of: does not support bogus:/)
      end

      # `_symbol_keyed_bag` converts Strings and leaves anything else exactly as it came, so the offender is
      # still named through the seam that reads it without dispatching to it.
      it "still names a key it cannot symbolize by class rather than running its own to_s" do
        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: { 7 => 1, "klass" => Integer } } } }
          .to raise_error(ArgumentError, /of: does not support a name of class Integer/)
      end

      it "still refuses a nested bag's `on:`" do
        inner = string_keyed(klass: Integer, on: :create)

        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: inner } } }
          .to raise_error(ArgumentError, /`on:` inside an `of:` bag/)
      end

      it "still refuses an option an axis bag cannot honour" do
        axis = string_keyed(klass: Integer, if: :flag)

        expect { build_axn { expects :m, type: Hash, of: { values: axis } } }
          .to raise_error(ArgumentError, /of: values: does not support if:/)
      end

      it "still refuses a nested bag that constrains nothing" do
        inner = string_keyed(klass: [])

        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: inner } } }
          .to raise_error(ArgumentError, /of: klass: names an empty union/)
      end

      it "still refuses a nested message: with nothing to describe" do
        bag = string_keyed(shape: { members: [], container: Hash }, message: "nope")

        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: bag } } }
          .to raise_error(ArgumentError, /of: message: on :m has nothing to describe/)
      end

      it "reports one option declared under both spellings, naming the nested bag" do
        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: { "klass" => Integer, :klass => String } } } }
          .to raise_error(ArgumentError, /the `of:` option bag declares :klass twice/)
      end

      it "reports one option declared under both spellings, naming the axis" do
        expect { build_axn { expects :m, type: Hash, of: { values: { "klass" => Integer, :klass => String } } } }
          .to raise_error(ArgumentError, /#{Regexp.escape('the `of: { values: … }` option bag declares :klass twice')}/)
      end

      # The defaulting-container refusal is judged ahead of the canonicalization at every rung, for the reason
      # it is judged ahead of it at the first: canonicalizing REPLACES the bag with a plain Hash of its
      # entries, which has no default left for the check to see.
      it "still refuses a nested bag that answers a missing key from a Hash default" do
        bag = Hash.new(String)
        bag["klass"] = Integer

        expect { build_axn { expects :m, type: Array, of: { klass: Array, of: bag } } }
          .to raise_error(ArgumentError, /answers a missing key from a Hash default/)
      end

      it "still refuses a defaulting axis bag" do
        bag = Hash.new(String)
        bag["klass"] = Integer

        expect { build_axn { expects :m, type: Hash, of: { values: bag } } }
          .to raise_error(ArgumentError, /answers a missing key from a Hash default/)
      end
    end
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

  # The same defect as a String-keyed bag, arriving from the other side: the options are not in the bag's ENTRIES
  # at all. axn copies every container it stores entry-wise, so a default cannot come along — and ActiveModel
  # rebuilds a validator's options into a Hash of its own besides, so a default never reached a validator even
  # when axn stored the caller's bag (`type: Hash.new(String)` failed every CALL with "must supply :klass", a key
  # the author believes they supplied). Reported at declaration instead of on a call.
  describe "a bag that answers missing keys from a Hash default" do
    # `Hash.new(value)` behind a method call, because `Lint/SharedMutableDefault` objects to the very
    # declaration under test (a mutable default IS what a members list or a metadata String is).
    def defaulting(value) = Hash.new(value)

    it "rejects `Hash.new(value)`, naming the bag" do
      bag = defaulting(String)

      expect { build_axn { expects :a, type: bag } }
        .to raise_error(ArgumentError, /the `type:` option bag answers a missing key from a Hash default.*Write the options out as entries/m)
    end

    it "rejects a default_proc bag" do
      bag = Hash.new { |_h, _key| String }

      expect { build_axn { expects :a, type: bag } }.to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end

    # The CONTAINER is the defect, not a missing key: a bag whose `klass:` is a real entry still answers every
    # OTHER key from the default — `type: { klass: String }` with a default is also `if: String`, a truthy gate
    # nothing declared — so it is refused whatever it happens to hold.
    it "rejects a bag carrying a real entry alongside the default" do
      bag = defaulting(String)
      bag[:klass] = String

      expect { build_axn { expects :a, type: bag } }.to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end

    # Refused under every KEY SPELLING, which a String-keyed bag was not: canonicalizing keys REPLACES the
    # bag with a plain Hash of its entries, and a plain Hash has no default — so the check that owns this
    # rule read a copy the defect had already been erased from, and the declaration went through in silence.
    # Canonicalization declines to replace a defaulting bag for exactly that reason, leaving the original for
    # the check to judge.
    it "rejects a String-keyed defaulting bag" do
      bag = defaulting(String)
      bag["klass"] = String

      expect { build_axn { expects :a, type: bag } }
        .to raise_error(ArgumentError, /the `type:` option bag answers a missing key from a Hash default/)
    end

    it "rejects a mixed-key defaulting bag" do
      bag = defaulting(String)
      bag[:klass] = String
      bag["message"] = "must be a String"

      expect { build_axn { expects :a, type: bag } }
        .to raise_error(ArgumentError, /the `type:` option bag answers a missing key from a Hash default/)
    end

    it "rejects a String-keyed default_proc bag" do
      bag = Hash.new { |_h, _key| String }
      bag["klass"] = String

      expect { build_axn { expects :a, type: bag } }.to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end

    # The form a Rails author actually hands in, and the one the erasure hit hardest: an indifferent-access
    # bag stores every key as a String however you write it, so a defaulting one was accepted under BOTH
    # spellings. (`.with_indifferent_access` on a literal carries no default and is untouched — see above.)
    it "rejects a defaulting indifferent-access bag, whose keys are Strings whatever you write" do
      bag = ActiveSupport::HashWithIndifferentAccess.new(String)
      bag[:klass] = String

      expect { build_axn { expects :a, type: bag } }
        .to raise_error(ArgumentError, /the `type:` option bag answers a missing key from a Hash default/)
    end

    # Both readers stay Hash's own here too — the erasure is what a lying subclass would otherwise be handed
    # for free, since a canonicalized bag has no default for the guard downstream to catch it out with.
    it "does not let a String-keyed bag deny its own default" do
      liar = Class.new(Hash) do
        def default(*) = nil
        def default_proc = nil
      end.new(String)
      liar["klass"] = String

      expect { build_axn { expects :a, type: liar } }.to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end

    # Two spellings of one option is reported ahead of the default, on the bag axn declines to canonicalize as
    # much as on the one it canonicalizes: the ambiguity is decided while the canonical bag is being built, and
    # the author fixing the double key then meets the container defect underneath it.
    it "reports one option under both spellings ahead of the default" do
      bag = defaulting(%w[z])
      bag["in"] = %w[x]
      bag[:in] = %w[y]

      expect { build_axn { expects :a, inclusion: bag } }
        .to raise_error(ArgumentError, /the `inclusion:` option bag declares :in twice/)
    end

    # The skip is on the DEFAULT, not on being a Hash: a String-keyed bag with the `default: nil` every Hash
    # literal has is canonicalized exactly as before, and validates.
    it "still canonicalizes a String-keyed bag whose default is nil" do
      bag = defaulting(nil)
      bag["klass"] = String
      klass = build_axn { expects :a, type: bag }

      expect(klass.call(a: "x")).to be_ok
      expect(klass.call(a: 1)).not_to be_ok
    end

    # Every bag axn detaches, whichever validator owns it — the guard is on the container, so there is no
    # per-validator list to keep in step.
    %i[of inclusion validate model presence numericality].each do |option|
      it "rejects a defaulting `#{option}:` bag too" do
        bag = defaulting(String)

        expect { build_axn { expects :a, type: Array, option => bag } }
          .to raise_error(ArgumentError, /the `#{option}:` option bag answers a missing key from a Hash default/)
      end
    end

    it "rejects a raw `shape:` whose members come from the default" do
      shape = defaulting([Axn::Core::Contract::ShapeConfig.new(field: :m, validations: {})])
      shape[:container] = Hash

      expect { build_axn { expects :payload, type: Hash, shape: } }
        .to raise_error(ArgumentError, /the `shape:` answers a missing key from a Hash default/)
    end

    it "rejects a defaulting nested shape, naming the member it hangs from" do
      nested = defaulting([Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: {})])
      nested[:container] = Hash
      member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: Hash, shape: nested })

      expect { build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /the nested `shape:` at shape member `m` answers a missing key from a Hash default/)
    end

    # A shape node's keys are canonicalized by the same pass, so both shape reports had the same hole — and a
    # String-keyed one reported the wrong defect rather than none: the copy carried no `members:` either, so a
    # shape supplying them through its default was refused for having none at all.
    it "rejects a String-keyed raw `shape:` whose members come from the default" do
      shape = defaulting([Axn::Core::Contract::ShapeConfig.new(field: :m, validations: {})])
      shape["container"] = Hash

      expect { build_axn { expects :payload, type: Hash, shape: } }
        .to raise_error(ArgumentError, /the `shape:` answers a missing key from a Hash default/)
    end

    it "rejects a String-keyed defaulting nested shape, naming the member it hangs from" do
      nested = defaulting([Axn::Core::Contract::ShapeConfig.new(field: :deep, validations: {})])
      nested["container"] = Hash
      member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: Hash, shape: nested })

      expect { build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /the nested `shape:` at shape member `m` answers a missing key from a Hash default/)
    end

    it "rejects a String-keyed defaulting bag inside a shape member" do
      bag = defaulting(String)
      bag["klass"] = String
      member = Axn::Core::Contract::ShapeConfig.new(field: :m, validations: { type: bag })

      expect { build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /the `type:` option bag answers a missing key from a Hash default/)
    end

    # A member's own two grammar levels are held to it as well: the validations Hash and the metadata Hash are
    # each copied entry-wise, so a default there is dropped exactly as a bag's is.
    it "rejects a member whose validations Hash defaults" do
      validations = defaulting({ klass: String })
      member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations:)

      expect { build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /the validations of shape member `a` answers a missing key from a Hash default/)
    end

    it "rejects a member whose metadata Hash defaults" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {}, metadata: defaulting("the a"))

      expect { build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /the metadata of shape member `a` answers a missing key from a Hash default/)
    end

    # Both readers are Hash's own, bound: a subclass overriding them is exactly the case the guard is about, so
    # its answer cannot be the one that decides.
    it "does not let a bag deny its own default" do
      liar = Class.new(Hash) do
        def default(*) = nil
        def default_proc = nil
      end.new(String)

      expect { build_axn { expects :a, type: liar } }.to raise_error(ArgumentError, /answers a missing key from a Hash default/)
    end

    # `default: nil` is what an ordinary Hash literal has, so nothing about the common case changes — and the
    # bag still validates, rather than being accepted and ignored.
    it "leaves a bag whose default is nil alone" do
      bag = defaulting(nil)
      bag[:klass] = String
      klass = build_axn { expects :a, type: bag }

      expect(klass.call(a: "x")).to be_ok
      expect(klass.call(a: 1)).not_to be_ok
    end
  end

  # `optional:` is how a NAMED position spells its tolerance — a shape member takes it today, alongside
  # `allow_nil:`/`allow_blank:`, with the granularity those names imply. A bag describes an UNNAMED position,
  # so it takes the same three, and the sugar is canonicalized into the pair at declaration exactly as
  # `_parse_field_configs` canonicalizes a field's (`allow_blank ||= optional`) — nothing downstream reads
  # three keys where the field reads two.
  describe "a bag's tolerance vocabulary" do
    it "canonicalizes optional: into allow_blank: at an element position" do
      action = build_axn { expects :f, type: Array, of: { klass: String, optional: true } }
      bag = action.internal_field_configs.first.validations[:of]

      expect(bag).to include(allow_blank: true)
      expect(bag).not_to include(:optional)
    end

    it "canonicalizes optional: at a map axis" do
      action = build_axn { expects :f, type: Hash, of: { values: { klass: String, optional: true } } }
      axis = action.internal_field_configs.first.validations[:of][:values]

      expect(axis).to include(allow_blank: true)
      expect(axis).not_to include(:optional)
    end

    it "canonicalizes optional: inside a nested bag" do
      action = build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: String, optional: true } } }
      inner = action.internal_field_configs.first.validations[:of][:of]

      expect(inner).to include(allow_blank: true)
      expect(inner).not_to include(:optional)
    end

    it "leaves an author-written allow_nil: alone rather than widening it to blank" do
      action = build_axn { expects :f, type: Array, of: { klass: String, allow_nil: true } }
      bag = action.internal_field_configs.first.validations[:of]

      expect(bag).to include(allow_nil: true)
      expect(bag).not_to include(:allow_blank)
    end

    it "still refuses a bag that constrains nothing but its own tolerance" do
      expect { build_axn { expects :f, type: Array, of: { optional: true } } }
        .to raise_error(ArgumentError, /of: must constrain something/)
    end
  end
end
