# frozen_string_literal: true

# A declared name becomes a JSON property name — in the reflected schema for an inbound field, in
# serialized output for an outbound one — so it carries the same UTF-8 promise the serializer enforces on a
# Hash key. Two names that collapse onto one property, and a name with no UTF-8 rendering at all, are
# rejected when the class is defined: both are knowable from the declarations alone, and by the time a call
# or a serializing adapter would notice, the business logic and its side effects have already run.
RSpec.describe "declaration-time property name collisions" do
  # Two distinct Symbols, one JSON property: the same text in two encodings. Symbols carry bytes plus an
  # encoding, while a property name is text, so these are separate Hash keys and one property.
  def utf8_name = :café
  def latin1_name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

  # Bytes with no UTF-8 rendering at all. ASCII-8BIT is mandatory here (see the plan's fixture note).
  def unrenderable_name = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym

  describe "the canonicalization this check shares with the renderer" do
    # The declaration check and the rendering it predicts must agree, so the contract layer calls the
    # renderer's canonicalization rather than re-deriving it. Asserted here so narrowing the renderer's
    # public surface fails loudly rather than silently disarming the guard.
    it "is publicly callable and collapses two encodings of one property" do
      expect(Axn::Reflection::Values).to respond_to(:canonical_wire_key)
      expect(Axn::Reflection::Values.canonical_wire_key(latin1_name)).to eq("café")
      expect(Axn::Reflection::Values.canonical_wire_key(utf8_name)).to eq("café")
    end
  end

  describe "two names that collapse onto one property" do
    it "rejects them on exposes" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on expects" do
      names = [utf8_name, latin1_name]

      expect { build_axn { expects(*names) } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them across separate declarations, not just within one batch" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          expects first
          expects second
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "names both spellings and the fix" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message).to include(":café", 'caf\xE9', "stay distinct once converted to UTF-8")
      }
    end

    it "rejects two subfield leaf names under one route" do
      leaves = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects :payload, type: Hash
          expects(*leaves, on: :payload)
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "still allows one leaf spelling under two different routes" do
      leaf = utf8_name

      klass = build_axn do
        expects :billing, type: Hash
        expects :shipping, type: Hash
        expects leaf, on: :billing, as: :billing_city, optional: true
        expects leaf, on: :shipping, as: :shipping_city, optional: true
      end

      expect(klass.subfield_configs.size).to eq(2)
    end
  end

  describe "a name with no UTF-8 rendering" do
    it "is rejected on expects" do
      name = unrenderable_name

      expect { build_axn { expects name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected on exposes" do
      name = unrenderable_name

      expect { build_axn { exposes name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected before the collision check, so two of them do not report a shared property" do
      names = [unrenderable_name, "worse\xFE".dup.force_encoding("ASCII-8BIT").to_sym]

      expect { build_axn { expects(*names) } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "names the offending bytes escaped to ASCII and the fix" do
      name = unrenderable_name

      expect { build_axn { expects name } }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include('bad\xFF', "Declare it under a UTF-8 name")
      }
    end
  end

  describe "the identical-name duplicate this generalizes" do
    it "keeps its existing message" do
      expect do
        build_axn do
          expects :foo, type: String
          expects :foo, numericality: { greater_than: 10 }
        end
      end.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
    end

    it "names every offending occurrence, not just the first" do
      expect { build_axn { expects :foo, :foo, :foo } }
        .to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo, foo")
    end

    # The message names each offender by its canonical property. Naming it by the Symbol would concatenate a
    # non-UTF-8 name into UTF-8 prose, and the Encoding::CompatibilityError from building the message would
    # reach the caller in place of the duplicate error it was trying to report.
    it "reports a non-UTF-8-encoded name as a duplicate rather than an encoding failure" do
      name = latin1_name

      expect do
        build_axn do
          expects name
          expects name
        end
      end.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
        expect(error.message).to include("café")
      }
    end

    it "reports a batch mixing encodings without the join failing" do
      names = [latin1_name, latin1_name, :naïve, :naïve]

      expect { build_axn { expects(*names) } }.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
        expect(error.message).to eq("Duplicate field(s) declared: café, naïve")
      }
    end
  end

  describe "shape member names" do
    it "rejects two members that collapse onto one property" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          expects :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects a duplicate member name, which previously kept only the last in the schema" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field :a, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared: :a\b/)
    end

    it "treats a symbol and a string spelling of one member name as one property" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field "a", type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "a"/)
    end

    it "rejects a member name with no UTF-8 rendering" do
      name = unrenderable_name

      expect do
        build_axn do
          expects :payload, type: Hash do
            field name, type: String
          end
        end
      end.to raise_error(ArgumentError, /a shape member name becomes a JSON property name/)
    end

    it "reports a collision in valid UTF-8 even when one spelling is not" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          expects :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
      }
    end

    # A member's own options are rejected inside the builder, which runs BEFORE the name guard can see the
    # resolved members — so every message that names a member has to survive a name with no UTF-8 rendering,
    # or the option check reports an Encoding::CompatibilityError from building its own message and the
    # naming defect never surfaces. Each combination below reaches a different one of those messages.
    describe "a member name with no UTF-8 rendering, combined with a member option" do
      it "still raises the declaration error when the member declares model:" do
        name = unrenderable_name

        expect do
          build_axn do
            expects :payload, type: Hash do
              field name, model: true
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      it "still raises the declaration error when an exposes member declares user_facing:" do
        name = unrenderable_name

        expect do
          build_axn do
            exposes :payload, type: Hash do
              field name, type: String, user_facing: true
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      it "still raises the declaration error when the member declares as:" do
        name = unrenderable_name

        expect do
          build_axn do
            expects :payload, type: Hash do
              field name, type: String, as: :renamed
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end

      # A raw `shape:` kwarg supplies members the builder never sees, so both guards judge them from the
      # resolved list — and the naming guard runs first, reporting the unusable name rather than the option
      # that could only ever have been the second problem with that member.
      it "reports the name, not the option, for a raw shape: member that also declares user_facing:" do
        member = Axn::Core::Contract::ShapeConfig.new(field: unrenderable_name, validations: {}, user_facing: true)

        expect { build_axn { exposes :payload, type: Hash, shape: { members: [member] } } }
          .to raise_error(ArgumentError, /a shape member name becomes a JSON property name/)
      end

      it "still raises the declaration error when the member carries no options at all" do
        name = unrenderable_name

        expect do
          build_axn do
            expects :payload, type: Hash do
              field name
            end
          end
        end.to raise_error(ArgumentError) { |error|
          expect(error.message.encoding).to eq(Encoding::UTF_8)
          expect(error.message).to satisfy(&:valid_encoding?)
        }
      end
    end

    it "reaches members nested inside a member's own block" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          expects :payload, type: Hash do
            field :inner, type: Hash do
              field first, type: String
              field second, type: Integer
            end
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "reaches members supplied as a raw shape: kwarg, which never route through the builder" do
      members = [
        Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
        Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}),
      ]

      expect { build_axn { expects :payload, type: Hash, shape: { members: } } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on an exposes shape too" do
      first = utf8_name
      second = latin1_name

      expect do
        build_axn do
          exposes :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "leaves distinct member names alone" do
      klass = build_axn do
        expects :payload, type: Hash do
          field :a, type: String
          field :b, type: Integer
        end
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq(%i[a b])
    end

    # A raw `shape:` kwarg accepts arbitrary objects as the shape Hash and as its members, while this guard
    # and the schema reflection that emits those members are two separate walks. So an object that lies —
    # about its own type, about which readers it has, or about whether two names are equal — must not be able
    # to make the guard skip a member the schema still emits, or to replace this error with one of its own.
    # Every question below is therefore answered from the real class and the real method table.
    describe "a shape supplied raw, by objects that lie about themselves" do
      # A Hash subclass denying that it is a Hash. `is_a?` is overridable, so a type test that dispatches it
      # skips the whole member walk — while reflection consumes the shape regardless and emits the property
      # twice, which is the exact defect this check exists to prevent.
      def sneaky_hash_class
        Class.new(Hash) do
          def is_a?(klass) = klass == Hash ? false : super
        end
      end

      # A member denying the `field` reader it defines. Membership decided by `respond_to?` would skip it,
      # while the schema reads `member.field` and emits the name anyway.
      def lying_member_class
        Class.new(Axn::Core::Contract::ShapeConfig) do
          # Mirrors Object#respond_to?'s real signature, which takes a positional include_all.
          def respond_to?(name, include_all = false) = name == :field ? false : super # rubocop:disable Style/OptionalBooleanParameter
        end
      end

      # A member served entirely by `method_missing` with NO `respond_to_missing?`. `Object#method` falls
      # back to `respond_to_missing?`, so the member looks reader-less to a method-table lookup — while the
      # schema's plain `member.field` dispatch reaches `method_missing` and emits the name.
      def ghost_member_class
        Class.new do
          def initialize(name) = @name = name

          # The absent respond_to_missing? IS the fixture: it is what makes a method-table lookup miss a
          # reader the schema's plain dispatch finds.
          def method_missing(reader, *_args) # rubocop:disable Style/MissingRespondToMissing
            case reader
            when :field then @name
            when :validations, :metadata then {}
            end
          end
        end
      end

      it "checks a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [
          Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
          Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}),
        ]
        shape[:container] = Hash

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      # The same lie against the sibling guard on the same walk: `user_facing:` on an outbound member is
      # rejected from the resolved members, so a shape that denies being a Hash must not skip that either.
      it "still rejects a user_facing: member inside a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :status, validations: {}, user_facing: true)]
        shape[:container] = Hash

        expect { build_axn { exposes :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /`status` does not support user_facing: on exposes/)
      end

      it "checks a member that denies the field reader it defines" do
        member_class = lying_member_class
        members = [
          member_class.new(field: utf8_name, validations: {}),
          member_class.new(field: latin1_name, validations: {}),
        ]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      # The tolerance the guard deliberately keeps: a member with genuinely no `field` has no name to
      # collide, so it is skipped rather than raising. Only a LIE about the reader is closed off. (Such a
      # member is still too minimal for the schema to reflect — that is the pre-existing contract for a raw
      # member, and orthogonal to what this guard decides.)
      it "still skips a member that genuinely defines no field reader" do
        members = [Object.new, Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]
        klass = nil

        expect { klass = build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }.not_to raise_error
        expect(klass.internal_field_configs.map(&:field)).to eq([:payload])
      end

      # A member whose name is a String subclass with a hostile `==`. Choosing between the two duplicate
      # messages by comparing the names dispatches that `==`, which raises in place of the declaration
      # error being reported — here a NotImplementedError, outside StandardError, so it escapes every
      # rescue in the framework rather than surfacing as the duplicate it is.
      it "reports the duplicate rather than an exception raised by a name's own ==" do
        hostile = Class.new(String) do
          def ==(_other) = raise(NotImplementedError, "hijacked from ==")
        end
        members = [
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
        ]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared: "dup" —/)
      end

      # A shape graph reachable from inside itself has no traversal at all: the walk recurses until the
      # stack overflows, and SystemStackError is outside StandardError, so it escapes every rescue rather
      # than settling into a reported failure. Rejected at declaration, naming the member that closes it.
      it "rejects a self-referential shape graph instead of overflowing the stack" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
        member.validations[:shape] = { members: [member], container: Hash }
        members = [member]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("a `shape:` graph cannot contain itself", "shape member `a`",
                                             "recurse until the stack overflows", "Give the nested shape its own members")
          }
      end

      it "rejects a self-referential shape graph on exposes too" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
        member.validations[:shape] = { members: [member], container: Hash }
        members = [member]

        expect { build_axn { exposes :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /a `shape:` graph cannot contain itself/)
      end

      it "checks a member whose field reader exists only through method_missing" do
        member_class = ghost_member_class
        members = [member_class.new(utf8_name), member_class.new(latin1_name)]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      it "still rejects a user_facing: member whose readers exist only through method_missing" do
        member = Class.new do
          # The absent respond_to_missing? IS the fixture: it is what makes a method-table lookup miss a
          # reader the schema's plain dispatch finds.
          def method_missing(reader, *_args) # rubocop:disable Style/MissingRespondToMissing
            case reader
            when :field then :status
            when :user_facing then true
            when :validations, :metadata then {}
            end
          end
        end.new
        members = [member]

        expect { build_axn { exposes :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(ArgumentError, /`status` does not support user_facing: on exposes/)
      end

      # A reader whose own body raises NoMethodError for a DIFFERENT name is a bug inside the member, not an
      # absent reader — it must propagate rather than be read as "this member has no name".
      it "propagates a NoMethodError raised inside a member's own field reader" do
        members = [Class.new { def field = nil.no_such_method }.new]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(NoMethodError, /no_such_method/)
      end

      # A shape object that builds a FRESH nested shape on every read never repeats an object, so no
      # identity-based cycle guard can see it — it is endless rather than cyclic, and would otherwise
      # recurse to SystemStackError (outside StandardError) while the class was being defined.
      it "rejects a shape graph that generates a fresh nested shape on every read" do
        generative = Class.new(Hash) do
          def [](key)
            return [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: self.class.new })] if key == :members
            return Hash if key == :container

            super
          end
        end
        shape = generative.new

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError) { |error|
            expect(error.message).to include("nested more than 64 levels deep", "generated rather than declared",
                                             "builds a fresh nested shape on every read")
          }
      end

      # `:container` is derived from `type:` for a raw shape that omits it, so a raw shape validates the way
      # a block-built one does. Skipping that derivation leaves a nil container reaching ShapeValidator,
      # which raises a bare `TypeError: class or module required` on EVERY call — a runtime crash in place of
      # the declaration-time answer. Neither the shape's `is_a?` nor its `key?` gets to decide.
      it "derives the container for a shape Hash that denies being a Hash" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
        expect(klass.call(payload: { a: 1 })).to be_ok
      end

      it "derives the container for a shape Hash whose key? claims it already has one" do
        shape = Class.new(Hash) do
          def key?(name) = name == :container ? true : super
        end.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
        expect(klass.call(payload: { a: 1 })).to be_ok
      end

      # The derived shape is a plain Hash assembled from the original's entries, not whatever the original's
      # `merge` chose to return — which can be any object at all, including one carrying no container.
      it "does not take the derived shape from the shape's own merge" do
        shape = Class.new(Hash) do
          def merge(*) = "not a hash at all"
        end.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: }
        derived = klass.internal_field_configs.first.validations[:shape]

        expect(derived).to be_instance_of(Hash)
        expect(derived[:container]).to eq(Hash)
        expect(derived[:members].size).to eq(1)
      end

      # An unusable container spelled out explicitly is the same unusable state as an omitted one, so it is
      # derived too rather than carried through to a per-call TypeError.
      it "derives the container for an explicit container: nil" do
        members = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        klass = build_axn { expects :payload, type: Hash, shape: { members:, container: nil } }

        expect(klass.internal_field_configs.first.validations.dig(:shape, :container)).to eq(Hash)
      end

      # Derivation still reports the declaration error it exists to produce when there is no structured
      # `type:` to derive from — the lie must not turn that into silence either.
      it "raises the declaration error when a lying shape Hash has no structured type: to derive from" do
        shape = sneaky_hash_class.new
        shape[:members] = [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]

        expect { build_axn { expects :payload, shape: } }
          .to raise_error(ArgumentError, /a shape block requires a single structured type:/)
      end

      # A shape reached twice as SIBLINGS is a diamond, not a cycle — the same object legitimately reused as
      # two members' nested shape. Guarding on the ancestor chain (not on "seen anywhere") is what keeps it
      # declarable.
      it "still allows one nested shape object reused by two sibling members" do
        nested = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }
        members = [
          Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: nested }),
          Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: nested }),
        ]

        klass = build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } }

        expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq(%i[a b])
      end
    end
  end

  # Every check runs before the class is mutated, so a rescued declaration error leaves nothing behind: no
  # half-committed config for a name that was rejected, and no reader for it. A class that survived the raise
  # carrying either would validate or expose a field the author was told they had not declared.
  describe "the class a rescued declaration error leaves behind" do
    it "carries no config and no reader for the rejected declaration" do
      names = [utf8_name, latin1_name]
      klass = build_axn
      methods_before = klass.instance_methods(false) + klass.private_instance_methods(false)

      expect { klass.expects(*names) }.to raise_error(Axn::DuplicateFieldError)

      expect(klass.internal_field_configs).to be_empty
      expect(klass.external_field_configs).to be_empty
      expect(klass.instance_methods(false) + klass.private_instance_methods(false)).to eq(methods_before)
    end
  end

  # The runtime defense this does NOT replace has its own coverage: a declaration check cannot see the keys
  # of a Hash the action builds during a call, so the serializer stays the last line for that case. It is
  # covered by the "colliding Hash keys" describe block in `spec/axn/reflection/values_spec.rb`, which owns
  # every assertion about the serializer's own behavior — do not duplicate it here; a second copy would add
  # a second place to maintain the serialization surface from, for no added protection.
end
