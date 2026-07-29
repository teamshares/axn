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

    it "rejects a duplicate member name, which today keeps only the last in the schema" do
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
  end

  # The runtime defense this does NOT replace has its own coverage: a declaration check cannot see the keys
  # of a Hash the action builds during a call, so the serializer stays the last line for that case. See
  # `spec/axn/reflection/values_spec.rb` "colliding Hash keys" — do not duplicate it here. That coverage
  # reaches the renderer directly, and PRO-2992 is in flight to make it reachable only through
  # `Axn::Extensions::Serialization`; a second copy of the same assertion in this file would become a second
  # thing to migrate for no added protection.
end
