# frozen_string_literal: true

require "benchmark"

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

  # A shape member that is NOT a ShapeConfig — the duck-typing tolerance ShapeValidator documents (only
  # `#field` and `#validations` are required). It never routes through ShapeConfig's constructor, so its name
  # is never normalized, which makes it the one route by which a caller-supplied name still reaches the
  # guards as itself.
  def duck_typed_member(name)
    Class.new do
      define_method(:field) { name }
      def validations = {}
      def metadata = {}
      def description = nil
      def optional? = true
    end.new
  end

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

  # Identity is the property a name renders as under its RESOLVED wire parent, not under the route as
  # written. A dotted `on:` and a subfield reader (or an `as:` alias of one) are two supported spellings of
  # the same route, so two leaf names that canonicalize to one property can sit under one parent with nothing
  # syntactic in common — and the reflected schema then emits that property twice. Resolution is taken from
  # the SubfieldTree the schema and the runtime already read, so the guard cannot disagree with them.
  describe "two routes that resolve to the same wire parent" do
    it "rejects colliding leaf names reached by a dotted route and a subfield reader" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :bar, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "foo\.bar\.café"/)
    end

    it "rejects them when the second route is an as: alias of the parent" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash, as: :aliased
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :aliased, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "foo\.bar\.café"/)
    end

    it "names both offenders with the route each was declared under" do
      utf8 = utf8_name
      latin1 = latin1_name

      expect do
        build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects utf8, on: "foo.bar", optional: true
          expects latin1, on: :bar, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message).to include(':café (on: "foo.bar")', 'caf\xE9" (on: :bar)')
      }
    end

    # One wire slot reached by two routes is a MERGED NODE — legitimate, gated on reader-name uniqueness
    # instead, and reflecting as one property. The rule is "canonical paths equal, RAW paths different", so
    # this stays declarable: it is the case where both halves are equal.
    it "still allows one leaf spelling reached by a dotted route and a reader route" do
      klass = build_axn do
        expects :address, type: Hash
        expects :billing, on: :address, type: Hash
        expects :zip, on: "address.billing", as: :zip_a, optional: true
        expects :zip, on: :billing, as: :zip_b, optional: true
      end

      expect(klass.input_schema.dig(:properties, :address, :properties, :billing, :properties).keys).to eq([:zip])
    end
  end

  # A `model:` field also claims the `<field>_id` axn generates for it, so an explicit sibling that
  # canonicalizes to the same property collapses onto it in the reflected schema. The generated name comes
  # from the same `Internal::FieldConfig.model_id_key` the schema uses, so the two cannot disagree about it.
  describe "a model:-generated <field>_id" do
    # A PORO with a finder — `spec/` runs without Rails.
    def widget_class
      Class.new do
        def self.name = "Widget"
        def self.find(_id) = new
      end
    end

    it "collides with an explicit _id declared in another encoding" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        build_axn do
          expects utf8, model: widget, optional: true
          expects latin1_id, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "café_id"/)
    end

    it "names it as generated, so the author is not sent looking for a name they never wrote" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        build_axn do
          expects utf8, model: widget, optional: true
          expects latin1_id, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /the `model:`-generated :café_id of :café/)
    end

    it "collides for a subfield model: too" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      expect do
        build_axn do
          expects :p, type: Hash
          expects utf8, on: :p, model: widget, optional: true
          expects latin1_id, on: :p, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "p\.café_id"/)
    end

    # THE control, and the reason the rule is "canonical equal, raw different" rather than "generated ids
    # join the claimed set". An explicit `<field>_id` in the SAME spelling is a supported pattern: schema
    # reflection merges the two (`properties[id_field] ||= id_prop`) and emits ONE property. Rejecting it
    # would break a legal declaration.
    it "still allows an explicit _id declared in the same spelling, merging into one property" do
      utf8 = utf8_name
      widget = widget_class

      klass = build_axn do
        expects utf8, model: widget, optional: true
        expects :café_id, optional: true
      end

      expect(klass.input_schema[:properties].keys).to eq([:café_id])
    end

    # Two `model:` fields whose generated ids would collide are already rejected on their own names — the
    # generated ids collide only when the names do, since the id is the name plus a fixed suffix. Asserted so
    # the mirror case is on the record as covered rather than unexamined.
    it "is unreachable for two model: fields, whose own names collide first" do
      utf8 = utf8_name
      latin1 = latin1_name
      widget = widget_class

      expect do
        build_axn do
          expects utf8, model: widget, optional: true
          expects latin1, model: widget, optional: true
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    # Checked mirror that does NOT apply: an outbound `model:` field reflects under its own name and emits no
    # generated `<field>_id` at all, so there is no generated property for an explicit one to collide with.
    it "has no outbound counterpart, since exposes generates no _id property" do
      utf8 = utf8_name
      latin1_id = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym
      widget = widget_class

      klass = build_axn do
        exposes utf8, model: widget, optional: true
        exposes latin1_id, optional: true
      end

      expect(klass.output_schema[:properties].size).to eq(2)
    end
  end

  # Six mechanisms can contribute a JSON property name at one node, and five rounds of review each surfaced a
  # different PAIR of them that could converge without either seeing the other. They are judged in one claim
  # space now, so the pairs below are the cross-product rather than a list of past defects: each is checked in
  # its encoding-distinct form (rejected) and its same-spelling form (a legal merge, emitting one property).
  # The mechanism list, with the reflection each mirrors, is in the comment on
  # `_reject_colliding_property_claims!`.
  describe "every mechanism that can name a property at one node" do
    def widget
      @widget ||= Class.new do
        def self.name = "Widget"
        def self.find(_id) = new
      end
    end

    # The reflected property names at one node, canonicalized — so "one property" and "two that collapse onto
    # one" are distinguishable, which is the whole question.
    def canonical_props(klass, *path)
      node = path.inject(klass.input_schema) { |acc, key| acc.dig(:properties, key) }
      (node[:properties] || {}).keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }
    end

    describe "a subfield leaf and a shape member of its parent" do
      it "rejects them when their names collapse onto one property" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects(:payload, type: Hash) { field utf8, type: String }
            expects latin1, on: :payload, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names the shape member and the subfield as the two sources" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects(:payload, type: Hash) { field utf8, type: String }
            expects latin1, on: :payload, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError) { |error|
          expect(error.message).to include("shape member :café of :payload", "(on: :payload)")
        }
      end

      it "still merges them into one property when the spelling matches" do
        utf8 = utf8_name

        klass = build_axn do
          expects(:payload, type: Hash) { field utf8, type: String }
          expects utf8, on: :payload, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end

      it "rejects them at depth, where the member is nested and the subfield is dotted" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects(:payload, type: Hash) { field(:mid, type: Hash) { field utf8, type: String } }
            expects latin1, on: "payload.mid", optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.mid\.café"/)
      end
    end

    describe "a shape member and a model:-generated <field>_id" do
      it "rejects them when their names collapse onto one property" do
        utf8_id = :café_id
        latin1 = latin1_name
        model = widget

        expect do
          build_axn do
            expects(:payload, type: Hash) { field utf8_id, type: String }
            expects latin1, on: :payload, model:, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café_id"/)
      end

      it "still merges them when the spelling matches" do
        utf8_id = :café_id
        utf8 = utf8_name
        model = widget

        klass = build_axn do
          expects(:payload, type: Hash) { field utf8_id, type: String }
          expects utf8, on: :payload, model:, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café_id"])
      end
    end

    describe "an implicit intermediate introduced by a dotted on:" do
      it "collides with a shape member of the same parent" do
        utf8 = utf8_name
        route = "payload.#{latin1_name}"

        expect do
          build_axn do
            expects(:payload, type: Hash) { field utf8, type: Hash }
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names itself as a nested key rather than as something the author declared" do
        utf8 = utf8_name
        route = "payload.#{latin1_name}"

        expect do
          build_axn do
            expects(:payload, type: Hash) { field utf8, type: Hash }
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /a nested key introduced by :leaf/)
      end

      it "collides with a subfield declared at the same parent" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects :payload, type: Hash
            expects :leaf, on: "payload.#{utf8}", optional: true
            expects latin1, on: :payload, type: Hash, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "collides with a model:-generated id at the same parent" do
        utf8 = utf8_name
        route = "payload.#{"caf\xE9_id".dup.force_encoding('ISO-8859-1').to_sym}"
        model = widget

        expect do
          build_axn do
            expects :payload, type: Hash
            expects utf8, on: :payload, model:, optional: true
            expects :leaf, on: route, optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café_id"/)
      end

      it "collides with another implicit intermediate at the same parent" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects :payload, type: Hash
            expects :a, on: "payload.#{utf8}", optional: true
            expects :b, on: "payload.#{latin1}", optional: true
          end
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "still merges with a subfield of the same spelling" do
        utf8 = utf8_name

        klass = build_axn do
          expects :payload, type: Hash
          expects :leaf, on: "payload.#{utf8}", optional: true
          expects utf8, on: :payload, type: Hash, optional: true
        end

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end
    end

    # A `Data`-typed field declaring a shape block emits its type's own members as properties beside the
    # shape's (Reflection::Schema#apply_structured_schema!), so those two sets share a node. This mechanism was
    # not on the review's list; it was found by walking the cross-product.
    describe "the members of a Data type declared alongside a shape" do
      it "rejects a shape member that collapses onto a Data member's property" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          build_axn { expects(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "names the Data type as the source" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          build_axn { expects(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::DuplicateFieldError, /a member of the .* type declared on :payload/)
      end

      # Naming the type runs a bound `Module#to_s`: a class can define its own, and one that raises would
      # replace the collision being reported — a ScriptError there escapes class definition entirely.
      it "reports the collision even when the type's own to_s raises" do
        shaped = Data.define(:café) do
          def self.to_s = raise(NotImplementedError, "hijacked from Class#to_s")
        end
        latin1 = latin1_name

        expect { build_axn { expects(:payload, type: shaped) { field latin1, type: String } } }
          .to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      it "still merges a shape member of the same spelling" do
        shaped = Data.define(:café)
        utf8 = utf8_name

        klass = build_axn { expects(:payload, type: shaped) { field utf8, type: String } }

        expect(canonical_props(klass, :payload)).to eq(["café"])
      end
    end

    # Mechanism 6's claims must match what `Schema#apply_structured_schema!` actually emits, in both
    # directions. The guard reads that decision from `Schema.shape_property_plan` rather than restating it:
    # restating it both missed a path the schema takes (`of:` element types seed `items[:properties]`) and
    # ignored a gate the schema honors (an output value that is not provably member-keyed), so it
    # simultaneously let a collapse through and rejected a legal declaration.
    describe "a structured type whose properties the schema does not emit" do
      # A custom `as_json`/`to_h` is what `serialize_value` would follow, so the serialized form is not
      # provably member-keyed and the OUTPUT property is left untyped — there is no property for a shape
      # member to collide with, and rejecting would break a declaration the author is entitled to write.
      it "does not reject an exposed Data type carrying a custom as_json" do
        custom = Data.define(:café) do
          def as_json(*) = { "totally" => "different" }
        end
        latin1 = latin1_name

        expect { build_axn { exposes(:thing, type: custom) { field latin1, type: String } } }.not_to raise_error
      end

      it "does not reject an exposed Data type carrying a custom to_h" do
        custom = Data.define(:café) do
          def to_h = { totally: "different" }
        end
        latin1 = latin1_name

        expect { build_axn { exposes(:thing, type: custom) { field latin1, type: String } } }.not_to raise_error
      end

      it "still rejects an exposed plain Data type, whose properties ARE emitted" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect { build_axn { exposes(:thing, type: shaped) { field latin1, type: String } } }
          .to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "thing\.café"/)
      end

      # INPUT reflects the shape a client is expected to send, regardless of how the value serializes, so a
      # custom as_json/to_h changes nothing inbound and the collision is real there.
      it "still rejects inbound, where serialization does not decide the schema" do
        custom = Data.define(:café) do
          def as_json(*) = { "totally" => "different" }
        end
        latin1 = latin1_name

        expect { build_axn { expects(:thing, type: custom) { field latin1, type: String } } }
          .to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "thing\.café"/)
      end

      # A scalar `of:` reads members off the element (`String#length`), which stays a string — the members are
      # validated but never become properties, so two of them cannot collapse.
      it "does not reject colliding member names under a scalar of:" do
        members = [Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                   Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {})]

        expect { build_axn { expects :list, type: Array, of: String, shape: { members:, container: Array } } }
          .not_to raise_error
      end
    end

    # An `of:` element type seeds the ARRAY ELEMENT's properties, which the shape's members then merge over —
    # a separate node from the field's own, and one the guard reached only once it started asking the schema
    # where properties land. (This also corrects the earlier claim that `of:` contributes nothing: its ELEMENT
    # TYPE does contribute property names, at the element node.)
    describe "an of: element type's members, inside the array's items" do
      def element_props(klass)
        klass.input_schema.dig(:properties, :list, :items, :properties).keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }
      end

      it "rejects a shape member that collapses onto an element type's property" do
        shaped = Data.define(:café)
        members = [Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: { type: String })]

        expect { build_axn { expects :list, type: Array, of: shaped, shape: { members:, container: Array } } }
          .to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "list\.\[\]\.café"/)
      end

      it "still merges an element type's property with a shape member of the same spelling" do
        shaped = Data.define(:café)
        members = [Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: { type: String })]

        klass = build_axn { expects :list, type: Array, of: shaped, shape: { members:, container: Array } }

        expect(element_props(klass)).to eq(["café"])
      end

      # Each array's element node is its own namespace, under that field's path — so the same element property
      # name under two different arrays is two properties, not a collision. (A subfield of an array-typed field
      # is rejected upstream for an unrelated reason, so an element property can never meet one.)
      it "keeps each array's element properties in their own namespace" do
        shaped = Data.define(:café)
        latin1_members = [Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: { type: String })]

        klass = build_axn do
          expects :list, type: Array, of: shaped, optional: true
          expects :other, type: Array, shape: { members: latin1_members, container: Array }, optional: true
        end

        other_props = klass.input_schema.dig(:properties, :other, :items, :properties).keys
                           .map { |k| Axn::Reflection::Values.canonical_wire_key(k) }

        expect(element_props(klass)).to eq(["café"])
        expect(other_props).to eq(["café"])
      end
    end

    describe "the outbound claim space" do
      it "rejects a Data member colliding with an exposed shape member" do
        shaped = Data.define(:café)
        latin1 = latin1_name

        expect do
          build_axn { exposes(:payload, type: shaped) { field latin1, type: String } }
        end.to raise_error(Axn::DuplicateFieldError, /both resolve to the JSON property "payload\.café"/)
      end

      # Inbound and outbound are separate spaces: one name may legitimately be both expected and exposed, and
      # they are emitted into different schemas.
      it "does not compare an inbound name against an outbound one" do
        utf8 = utf8_name
        latin1 = latin1_name

        expect do
          build_axn do
            expects utf8, optional: true
            exposes latin1, optional: true
          end
        end.not_to raise_error
      end
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

  # A dotted `on:` segment becomes a JSON property name in the reflected schema — the root names a declared
  # field, each deeper segment is an implicit nested key — so it carries the same UTF-8 promise a declared name
  # does, enforced by the same check. The property-claim collector cannot stand in for this: an unrenderable
  # segment canonicalizes to nothing, so there is no property to compare and the claim is dropped while the
  # schema still emits the segment.
  describe "a dotted on: route segment with no UTF-8 rendering" do
    it "is rejected at declaration rather than reaching JSON.generate" do
      route = "payload.#{unrenderable_name}"

      expect do
        build_axn do
          expects :payload, type: Hash
          expects :leaf, on: route, optional: true
        end
      end.to raise_error(ArgumentError, /a nested key in `on:` becomes a JSON property name/)
    end

    it "names the offending segment escaped to ASCII and the fix" do
      route = "payload.#{unrenderable_name}"

      expect do
        build_axn do
          expects :payload, type: Hash
          expects :leaf, on: route, optional: true
        end
      end.to raise_error(ArgumentError) { |error|
        expect(error.message).to include('bad\xFF', "Declare it under a UTF-8 name")
        expect(error.message.encoding).to eq(Encoding::UTF_8)
        expect(error.message).to satisfy(&:valid_encoding?)
      }
    end

    # An unrenderable ROOT used to reach the reader-existence check, whose message interpolates `on:` — so the
    # caller got an Encoding::CompatibilityError from the reporting instead of the defect being reported.
    it "is rejected as the naming defect even in the root position" do
      root = unrenderable_name

      expect { build_axn { expects :leaf, on: root, optional: true } }
        .to raise_error(ArgumentError, /a nested key in `on:` becomes a JSON property name/)
    end

    it "leaves a valid non-ASCII segment alone, emitting it as a property" do
      route = "payload.#{utf8_name}"

      klass = build_axn do
        expects :payload, type: Hash
        expects :leaf, on: route, optional: true
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys
                  .map { |k| Axn::Reflection::Values.canonical_wire_key(k) }).to eq(["café"])
    end

    it "leaves a plain ASCII dotted route alone" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :leaf, on: "payload.mid", optional: true
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq([:mid])
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

    # A member name is normalized to a Symbol at declaration, exactly as a top-level field name is, so these
    # two are not merely one property — they are one NAME, and the identical-duplicate message is the accurate
    # one. That also puts shape members in step with `expects :foo, "foo"`, which has always reported
    # "Duplicate field(s) declared: foo" rather than a collapse.
    it "treats a symbol and a string spelling of one member name as one name" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field "a", type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared: :a —/)
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
      # collide, so it is skipped rather than raising. Only a LIE about the reader is closed off. Reflection
      # skips such a member on the same terms, so declaration and emission agree about which members exist.
      it "still skips a member that genuinely defines no field reader" do
        members = [Object.new, Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})]
        klass = nil

        expect { klass = build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }.not_to raise_error
        expect(klass.internal_field_configs.map(&:field)).to eq([:payload])
        expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({ a: {} })
      end

      # A member whose name is a String subclass with a hostile `==`. Choosing between the two duplicate
      # messages by comparing the names dispatches that `==`, which raises in place of the declaration
      # error being reported — here a NotImplementedError, outside StandardError, so it escapes every
      # rescue in the framework rather than surfacing as the duplicate it is.
      def hostile_equality_name_class
        Class.new(String) do
          def ==(_other) = raise(NotImplementedError, "hijacked from ==")
        end
      end

      # A ShapeConfig normalizes its name to a Symbol at construction, so a String subclass with a hostile
      # `==` cannot even be STORED as a member name — the hazard is gone at its root rather than guarded
      # against, and the pair reports as the plain duplicate it now is.
      it "cannot store a hostile-== name on a ShapeConfig at all, and reports the duplicate" do
        hostile = hostile_equality_name_class
        members = [
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
          Axn::Core::Contract::ShapeConfig.new(field: hostile.new("dup"), validations: {}),
        ]

        expect(members.map { |m| m.field.class }).to eq([Symbol, Symbol])
        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared: :dup —/)
      end

      # A duck-typed member's reader is not ours to normalize, so this is the one route by which a
      # caller-supplied String name still reaches the spelling comparison — and where deciding "same spelling"
      # must still not dispatch the name's own `==`. It is what keeps that guard exercised.
      it "reports the duplicate for a duck-typed member whose name's own == raises" do
        hostile = hostile_equality_name_class
        members = [duck_typed_member(hostile.new("dup")), duck_typed_member(hostile.new("dup"))]

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
        expect(klass.input_schema.dig(:properties, :payload, :properties, :a, :properties).keys).to eq([:leaf])
      end

      # `[]` is the read every guard AND reflection makes, so a lie there must hide the members from BOTH —
      # that is what "a lie changes what both decide" means. The failure to prevent is the opposite: members
      # reaching reflection that no guard walked, which is what copying the shape's raw entries would do.
      describe "a shape whose [] hides the members its real entries carry" do
        def hidden_member_shape(*members)
          shape = Class.new(Hash) do
            def [](key)
              return [] if key == :members
              return nil if key == :container

              super
            end
          end.new
          shape.store(:members, members)
          shape
        end

        it "does not promote a colliding pair into the reflected schema" do
          shape = hidden_member_shape(Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                                      Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}))

          klass = build_axn { expects :payload, type: Hash, shape: }

          expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({})
        end

        it "does not promote a user_facing: member the outbound guard never saw" do
          shape = hidden_member_shape(Axn::Core::Contract::ShapeConfig.new(field: :status, validations: {}, user_facing: true))

          klass = build_axn { exposes :payload, type: Hash, shape: }

          expect(klass.external_field_configs.first.validations.dig(:shape, :members)).to eq([])
        end

        # The worst of the three: a cyclic member the guard never walked reaches reflection, whose own walk
        # has no cycle guard, and the stack overflows outside StandardError — during schema reflection rather
        # than at declaration.
        it "does not promote a cyclic member into a graph reflection then walks" do
          member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})
          member.validations[:shape] = { members: [member], container: Hash }
          shape = hidden_member_shape(member)

          klass = build_axn { expects :payload, type: Hash, shape: }

          expect(klass.input_schema.dig(:properties, :payload, :properties)).to eq({})
        end
      end

      # `nil?` is overridable, so every "is this absent?" test on a caller value asks `nil` instead.
      it "does not let a members list claiming to be nil hide itself from the walk" do
        members = Class.new(Array) { def nil? = true }.new
        members.push(Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                     Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}))

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
      end

      it "does not let a container whose nil? raises hijack the declaration" do
        raising_nil = Class.new { def nil? = raise(NotImplementedError, "hijacked from nil?") }
        shape = Class.new(Hash) do
          define_method(:[]) { |key| key == :container ? raising_nil.new : super(key) }
        end.new
        shape.store(:members, [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: {})])

        klass = nil
        expect { klass = build_axn { expects :payload, type: Hash, shape: } }.not_to raise_error
        # The container the caller supplied is left alone — it said it had one — but nothing it defines got
        # to decide that. Read through `[]` rather than `dig`, which bypasses the override under test.
        stored = klass.internal_field_configs.first.validations[:shape]
        expect(stored[:container].class).to eq(raising_nil)
      end

      # A NoMethodError subclass whose `name` is an object with a raising `==`. Deciding "does this mean no
      # such reader?" must not dispatch that `==`: the NotImplementedError it raises is a ScriptError, which
      # escapes every rescue in the framework, in place of the member's own NoMethodError.
      it "does not dispatch == on a hostile NoMethodError#name" do
        hostile_name = Class.new { def ==(_other) = raise(NotImplementedError, "hijacked from ==") }
        evil_error = Class.new(NoMethodError) { define_method(:name) { hostile_name.new } }
        members = [Class.new do
          def initialize(error_class) = @error_class = error_class

          # No respond_to_missing?, so the fallback dispatch is the path reached.
          def method_missing(_reader, *_args) = raise(@error_class, "boom") # rubocop:disable Style/MissingRespondToMissing
        end.new(evil_error)]

        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(NoMethodError, "boom")
      end

      # Every message naming a member is built from a name the walk already read on the way down. Reading it
      # again once a failure is being reported is the same hazard as `inspect`: this member answers the first
      # read and raises on the second, so a re-read replaces the declaration error with its exception.
      it "reports a cycle without re-reading the member's name" do
        member = Class.new do
          def initialize
            @reads = 0
          end

          def field
            @reads += 1
            raise(NotImplementedError, "hijacked from a second read") if @reads > 1

            :a
          end

          def validations = @validations ||= {}
        end.new
        shape = { members: [member], container: Hash }
        member.validations[:shape] = shape

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /cannot contain itself.*shape member `a`/)
      end

      # A nested shape reused by two SIBLING members multiplies the distinct property paths beneath it: each
      # level doubles them, so N levels name 2^N properties. Shallow sharing — what anyone writes by hand — is
      # legal and cheap, and the walk remembers shapes it has already verified so each is checked once.
      def shared_sibling_shape(depth)
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }
        depth.times do
          shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { shape: }),
                              Axn::Core::Contract::ShapeConfig.new(field: :b, validations: { shape: })],
                    container: Hash }
        end
        shape
      end

      it "declares a nested shape shared between sibling members, without re-walking each route" do
        shape = shared_sibling_shape(10)
        elapsed = nil

        expect { elapsed = Benchmark.realtime { build_axn { expects :payload, type: Hash, shape: } } }.not_to raise_error
        expect(elapsed).to be < 1.0
      end

      # Past a point that sharing is not a schema anyone can use: the property count is exponential, and
      # `input_schema` walks the same paths (786k nodes at eighteen levels, measured). Rejecting at declaration
      # is the better of the two outcomes — the alternative is declaring cleanly and then hanging the first
      # time anything reflects the contract.
      it "rejects sharing deep enough that the property count is exponential" do
        shape = shared_sibling_shape(18)

        expect { build_axn { expects :payload, type: Hash, shape: } }
          .to raise_error(ArgumentError, /names more than 25000 JSON properties/)
      end

      it "reaches that rejection quickly rather than walking the whole graph first" do
        shape = shared_sibling_shape(22)
        elapsed = Benchmark.realtime do
          build_axn { expects :payload, type: Hash, shape: }
        rescue ArgumentError
          nil
        end

        expect(elapsed).to be < 1.0
      end

      # A member name that is neither String nor Symbol renders a property through its `to_s`, so it reaches
      # every one of these checks — while its `inspect` is real caller code. Dispatching that `inspect` to
      # build the error the name caused lets the name replace that error with an exception of its own, and one
      # outside StandardError then escapes class definition. Named by class instead, as the serializer names a
      # colliding Hash key. (Reachable only as a shape member's name: the field path symbolizes every declared
      # name before any guard runs — asserted in the last example here.)
      describe "a member name that is neither String nor Symbol, whose inspect raises" do
        def exotic_name_class
          Class.new do
            def initialize(rendering) = @rendering = rendering
            def to_s = @rendering
            def inspect = raise(NotImplementedError, "hijacked from #inspect")
          end
        end

        # These two reached the collision and unrenderable-name checks before a member name had to be a String
        # or a Symbol. The type rule now rejects such a name outright, ahead of both — a strictly earlier and
        # simpler answer to the same defect. `_inspect_field_name`'s class-naming branch stays live and
        # covered by the block-form option example below, which runs before a ShapeConfig is constructed.
        # A ShapeConfig cannot be CONSTRUCTED with such a name, so the rejection lands before any declaration
        # — earlier than the collision and unrenderable-name checks that used to be the first to see it.
        it "cannot be constructed on a ShapeConfig at all" do
          exotic = exotic_name_class

          expect { Axn::Core::Contract::ShapeConfig.new(field: exotic.new("dup"), validations: {}) }
            .to raise_error(ArgumentError, /a shape member name must be a String or a Symbol \(got a name of class /)
        end

        it "names the offender by class rather than dispatching its inspect" do
          exotic = exotic_name_class

          expect { Axn::Core::Contract::ShapeConfig.new(field: exotic.new("bad\xFF".dup.force_encoding("ASCII-8BIT")), validations: {}) }
            .to raise_error(ArgumentError) { |error|
              expect(error.message).to include("must be a String or a Symbol", "Declare the member under a String or Symbol name")
              expect(error.message.encoding).to eq(Encoding::UTF_8)
              expect(error.message).to satisfy(&:valid_encoding?)
            }
        end

        # A duck-typed member never routes through that constructor, so the resolved-member walk is the second
        # enforcement point for the same rule — without it the whole class would stay open.
        it "is rejected at declaration on a duck-typed member, which bypasses the constructor" do
          members = [duck_typed_member(exotic_name_class.new("dup"))]

          expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
            .to raise_error(ArgumentError, /a shape member name must be a String or a Symbol/)
        end

        # The block form's own option-rejection messages name the member through the same helper, so they
        # carry the same hazard — a third route to it, found by auditing the helper's callers.
        it "reports a block-form option error naming the member by class" do
          name = exotic_name_class.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))

          expect do
            build_axn do
              expects(:payload, type: Hash) { field name, model: true }
            end
          end.to raise_error(ArgumentError, /shape member `a name of class .*` does not support model:/)
        end

        # Every declared field name is symbolized before any guard runs, so `config.field` is always a Symbol
        # and these helpers can never meet an exotic name on the field path. Asserted so the reasoning behind
        # leaving the field-path messages untouched stays true rather than assumed.
        it "cannot reach the field path at all, which symbolizes every declared name" do
          klass = build_axn { expects "stringy", :symbolic }
          exotic = exotic_name_class.new("dup")

          expect(klass.internal_field_configs.map { |c| c.field.instance_of?(Symbol) }).to all(be(true))
          expect { build_axn { expects exotic } }.to raise_error(NoMethodError, /to_sym/)
        end
      end

      # `NoMethodError` inherits `name` from `NameError`, which is where the missing name is STORED, so the
      # stored symbol is read through NameError's own implementation. A subclass overriding `name` to raise
      # would otherwise replace the declaration verdict from inside the line that decides it — putting axn's
      # own Symbol on the left of the comparison does not help, because reading `e.name` is itself a dispatch.
      it "reads a NoMethodError's stored name through NameError, not through a subclass override" do
        raising_name = Class.new(NoMethodError) do
          def name = raise(NotImplementedError, "hijacked from #name")
        end
        ghost = Class.new do
          def initialize(error_class) = @error_class = error_class

          # No respond_to_missing?, so the dispatch fallback is the path reached, and the raised error stores
          # the missing name exactly as an implicit NoMethodError would.
          def method_missing(reader, *_args) = raise(@error_class.new("boom", reader)) # rubocop:disable Style/MissingRespondToMissing
        end
        members = [ghost.new(raising_name),
                   Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
                   Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {})]

        # The ghost is read as absent (its stored name matches what was asked for) and skipped, so the real
        # defect — the colliding pair beside it — is what gets reported.
        expect { build_axn { expects :payload, type: Hash, shape: { members:, container: Hash } } }
          .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
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
