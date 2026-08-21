# frozen_string_literal: true

RSpec.describe "sensitive: on shape members (PRO-2911)" do
  describe "static sensitive members" do
    it "redacts a sensitive Array-element member in inputs_for_logging (every element)" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end
      end

      instance = action.send(:new, items: [{ ssn: "111-11-1111", name: "Alice" },
                                           { ssn: "222-22-2222", name: "Bob" }])
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:items]).to eq([{ ssn: "[FILTERED]", name: "Alice" },
                                    { ssn: "[FILTERED]", name: "Bob" }])
    end

    it "redacts a sensitive Hash member in inputs_for_logging" do
      action = build_axn do
        expects :payload, type: Hash do
          field :token, type: String, sensitive: true
          field :user, type: String
        end
      end

      instance = action.send(:new, payload: { token: "s3cr3t", user: "alice" })
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:payload]).to eq({ token: "[FILTERED]", user: "alice" })
    end

    it "redacts a sensitive member nested inside a nested shape (recursion)" do
      action = build_axn do
        expects :order, type: Hash do
          field :customer, type: Hash do
            field :ssn, type: String, sensitive: true
            field :name, type: String
          end
        end
      end

      instance = action.send(:new, order: { customer: { ssn: "999-99-9999", name: "Zoe" } })
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:order][:customer]).to eq({ ssn: "[FILTERED]", name: "Zoe" })
    end

    it "redacts a sensitive member in execution_context inputs" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, type: String, sensitive: true
        end

        def call; end
      end

      instance = action.send(:new, items: [{ ssn: "111-11-1111" }])
      instance.call
      ctx = instance.execution_context

      expect(ctx[:inputs][:items]).to eq([{ ssn: "[FILTERED]" }])
    end

    it "includes the static sensitive member name in sensitive_fields (and not the plain sibling)" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end
      end

      expect(action.sensitive_fields).to include(:ssn)
      expect(action.sensitive_fields).not_to include(:name)
    end
  end

  describe "dynamic sensitive members" do
    it "redacts a Proc member only when the predicate resolves truthy against the instance" do
      action = build_axn do
        expects :redact, type: :boolean, default: false
        expects :items, type: Array do
          field :ssn, type: String, sensitive: -> { redact }
        end
      end

      redacted = action.send(:new, redact: true, items: [{ ssn: "111-11-1111" }])
      expect(redacted.send(:inputs_for_logging)[:items]).to eq([{ ssn: "[FILTERED]" }])

      visible = action.send(:new, redact: false, items: [{ ssn: "111-11-1111" }])
      expect(visible.send(:inputs_for_logging)[:items]).to eq([{ ssn: "111-11-1111" }])
    end

    it "redacts a Symbol member resolved against an instance method" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, type: String, sensitive: :hide_ssn?
        end

        def call; end

        private

        def hide_ssn? = true
      end

      instance = action.send(:new, items: [{ ssn: "111-11-1111" }])
      expect(instance.send(:inputs_for_logging)[:items]).to eq([{ ssn: "[FILTERED]" }])
    end

    it "reports dynamic sensitive members via _has_dynamic_sensitive_fields?" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, sensitive: -> { true }
        end
      end

      expect(action._has_dynamic_sensitive_fields?).to be true
    end
  end

  describe "inspect (ContextFacadeInspector) redaction" do
    it "redacts a sensitive Array-element member in internal_context.inspect (not just logs)" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end

        def call; end
      end

      inspected = inbound_facade(action.call(items: [{ ssn: "111-11-1111", name: "Alice" }]).__action__).inspect

      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("111-11-1111")
      expect(inspected).to include("Alice")
    end

    it "redacts a sensitive Hash member in internal_context.inspect" do
      action = build_axn do
        expects :payload, type: Hash do
          field :token, type: String, sensitive: true
          field :user, type: String
        end

        def call; end
      end

      inspected = inbound_facade(action.call(payload: { token: "s3cr3t", user: "alice" }).__action__).inspect

      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("s3cr3t")
    end

    it "redacts a sensitive member nested inside a nested shape in inspect" do
      action = build_axn do
        expects :order, type: Hash do
          field :customer, type: Hash do
            field :ssn, type: String, sensitive: true
          end
        end

        def call; end
      end

      inspected = inbound_facade(action.call(order: { customer: { ssn: "999-99-9999" } }).__action__).inspect

      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("999-99-9999")
    end

    it "redacts the whole value when the parent field is itself sensitive (not just the nested member)" do
      action = build_axn do
        expects :items, type: Array, sensitive: true do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end

        def call; end
      end

      inspected = inbound_facade(action.call(items: [{ ssn: "111-11-1111", name: "Alice" }]).__action__).inspect

      expect(inspected).to include("items: [FILTERED]")
      # The non-sensitive sibling must not leak out of a wholesale-redacted parent.
      expect(inspected).not_to include("Alice")
    end

    it "redacts a sensitive member declared inside a subfield's shape block" do
      action = build_axn do
        expects :payload, type: Hash
        expects :details, on: :payload, type: Hash do
          field :token, type: String, sensitive: true
          field :user, type: String
        end

        def call; end
      end

      inspected = inbound_facade(action.call(payload: { details: { token: "s3cr3t", user: "alice" } }).__action__).inspect

      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("s3cr3t")
      expect(inspected).to include("alice")
    end
  end

  describe "duck-typed raw shape members (no #sensitive reader)" do
    # `shape: { members: [...] }` may be supplied raw with member objects implementing only the
    # documented #field/#validations contract. The sensitive-name collectors must not assume #sensitive.
    let(:raw_member) { Struct.new(:field, :validations).new(:name, { type: { klass: String } }) }

    it "does not raise from sensitive_fields for a member lacking #sensitive" do
      member = raw_member
      action = build_axn do
        expects :items, type: Hash, shape: { members: [member] }
      end

      expect { action.sensitive_fields }.not_to raise_error
      expect(action.sensitive_fields).to eq([])
    end

    it "does not raise from inspect for a member lacking #sensitive" do
      member = raw_member
      action = build_axn do
        expects :items, type: Hash, shape: { members: [member] }

        def call; end
      end

      result = action.call(items: { name: "Alice" })
      expect { inbound_facade(result.__action__).inspect }.not_to raise_error
    end

    # A raw member reaches redaction without passing through `expects`, so the `sensitive:` grammar is enforced
    # where every member meets it whatever built it: the declaration walk, which reads the value once on its way
    # into the snapshot. `ShapeConfig`'s constructor holds the same rule for the block form, where it is the first
    # thing to see one. Without the walk's check, a value that is not a resolution rule reached a stored contract
    # from a member of some other class — or, on a Ruby whose `Data#with` skips a custom `initialize`, from a
    # `ShapeConfig` copy — and took the member out of the redaction set silently.
    describe "the sensitive: grammar on a raw member" do
      let(:grammar_error) { /sensitive: must be true, false, a Symbol naming an action method, or a Proc/ }

      def declared_with(member)
        build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
      end

      it "rejects it on a ShapeConfig supplied directly" do
        expect { Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: {}, sensitive: "yes") }
          .to raise_error(ArgumentError, grammar_error)
      end

      # Whether `Data#with` re-runs a custom `initialize` is a Ruby-version detail (3.3 does; 3.2 does not), so
      # the promise is asserted where it holds on every supported Ruby: the copy never reaches a stored contract.
      # Both steps are inside the expectation, so either one may be the one that raises.
      it "rejects it on a derived copy, before the copy can reach a contract" do
        original = Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: {}, sensitive: true)

        expect { declared_with(original.with(sensitive: "yes")) }.to raise_error(ArgumentError, grammar_error)
      end

      # Being a `Data` is not being a `ShapeConfig`: a member of the caller's own `Data` class reaches the walk
      # having run no ShapeConfig constructor at all — on every Ruby, not just the one whose `with` skips it.
      it "rejects it on a member of the caller's own Data class, at declaration" do
        member = Data.define(:field, :validations, :sensitive).new(field: :ssn, validations: {}, sensitive: "yes")

        expect { declared_with(member) }.to raise_error(ArgumentError, grammar_error)
      end

      it "rejects it on a duck-typed member, at declaration" do
        member = Struct.new(:field, :validations, :sensitive).new(:ssn, {}, "yes")

        expect { declared_with(member) }.to raise_error(ArgumentError, grammar_error)
      end

      it "still accepts a duck-typed member with no #sensitive reader at all" do
        member = Struct.new(:field, :validations).new(:ssn, {})

        expect { declared_with(member) }.not_to raise_error
      end

      # The check must not over-reach either: a derived copy carrying a value the grammar allows is an ordinary
      # declaration, and still redacts.
      it "accepts a derived copy whose sensitive: is in the grammar, and redacts it" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: {}, sensitive: false).with(sensitive: true)
        action = declared_with(member)

        expect(action.send(:new, payload: { ssn: "111-11-1111" }).send(:inputs_for_logging)[:payload]).to eq({ ssn: "[FILTERED]" })
      end

      # Reading the value at declaration also surfaces a reader that RAISES, at the author, on the same terms as
      # the `field`/`validations` reads beside it. It used to declare cleanly and then raise from every logged
      # call instead, where the guard around a side channel degraded the whole slice to a warning — so logging
      # was quietly broken for the life of the class rather than the declaration being reported.
      it "reports a #sensitive reader that raises, at declaration" do
        member = Struct.new(:field, :validations) do
          def sensitive = raise(NotImplementedError, "hostile sensitive reader")
        end.new(:ssn, {})

        expect { declared_with(member) }.to raise_error(NotImplementedError, /hostile sensitive reader/)
      end
    end

    # The tolerance runs one way only. A member that DEFINES `sensitive:` cannot opt out of redaction by
    # denying the reader — both paths read it from the real method table (`ShapeGraph`), so `inspect` cannot
    # print in the clear what logging redacts.
    it "redacts a member that hides its #sensitive reader, in logs AND inspect" do
      member = Struct.new(:field, :validations, :sensitive) do
        def respond_to?(name, *) = name.to_sym == :sensitive ? false : super
      end.new(:ssn, { type: { klass: String } }, true)
      action = build_axn do
        expects :payload, type: Hash, shape: { members: [member], container: Hash }

        def call; end
      end

      instance = action.send(:new, payload: { ssn: "111-11-1111" })
      expect(instance.send(:inputs_for_logging)[:payload]).to eq({ ssn: "[FILTERED]" })

      inspected = inbound_facade(action.call(payload: { ssn: "111-11-1111" }).__action__).inspect
      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("111-11-1111")
    end

    # A member's `sensitive:` is read ONCE, at declaration, and the value is stored in axn's own `ShapeConfig`.
    # Until it was, the redaction table keyed on the identity of the three config arrays — sound for everything
    # axn owns, blind to state inside a member the caller still held — so flipping the flag afterwards changed
    # the answer or did not, depending on nothing but whether anything had read the contract yet. Both
    # directions, both orders, and the DECLARED behaviour is what persists.
    describe "a member's sensitive: flipped after the class is declared" do
      def duck_member(sensitive) = Struct.new(:field, :validations, :sensitive).new(:ssn, {}, sensitive)

      def declared_with(member)
        build_axn do
          expects :payload, type: Hash, shape: { members: [member], container: Hash }

          define_method(:call) { nil } # define_method, not `def`: this is inside a method body
        end
      end

      def logged_ssn(action) = action.send(:new, payload: { ssn: "111-11-1111" }).send(:inputs_for_logging).dig(:payload, :ssn)

      [false, true].each do |read_first|
        context "with the contract #{read_first ? 'already read' : 'not yet read'}" do
          it "leaves a member declared sensitive: false in the clear when it is flipped on" do
            member = duck_member(false)
            action = declared_with(member)
            action.sensitive_fields if read_first
            member.sensitive = true

            expect(action.sensitive_fields).to eq([])
            expect(logged_ssn(action)).to eq("111-11-1111")
          end

          it "keeps a member declared sensitive: true redacted when it is flipped off" do
            member = duck_member(true)
            action = declared_with(member)
            action.sensitive_fields if read_first
            member.sensitive = false

            expect(action.sensitive_fields).to eq([:ssn])
            expect(logged_ssn(action)).to eq("[FILTERED]")
          end
        end
      end
    end

    # A duck-typed member's `sensitive:` is snapshotted at every depth, not only at the top of a shape — the
    # walk recurses into the nested `shape:` it carries and rebuilds that too.
    it "redacts a duck-typed sensitive member nested inside another shape, in logs and inspect" do
      inner = Struct.new(:field, :validations, :sensitive).new(:ssn, {}, true)
      outer = Struct.new(:field, :validations).new(:person, { type: { klass: Hash }, shape: { members: [inner], container: Hash } })
      action = build_axn do
        expects :payload, type: Hash, shape: { members: [outer], container: Hash }

        def call; end
      end

      instance = action.send(:new, payload: { person: { ssn: "111-11-1111" } })
      expect(instance.send(:inputs_for_logging).dig(:payload, :person)).to eq({ ssn: "[FILTERED]" })

      inspected = inbound_facade(action.call(payload: { person: { ssn: "111-11-1111" } }).__action__).inspect
      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("111-11-1111")
    end
  end

  describe "object-backed shapes (value isn't a Hash → wholesale masking)" do
    # ParameterFilter only redacts Hash keys, so an object value can't be filtered per-member. When a
    # shape member is sensitive but the value is an object (Data/Struct/PORO) or malformed input, the
    # whole value is masked wholesale — over-redacting its non-sensitive siblings rather than leaking.
    let(:person) { Data.define(:name, :ssn) }

    it "masks a class-backed shape value wholesale in logs when it carries a sensitive member" do
      klass = person
      action = build_axn do
        expects :person, type: klass do
          field :name, method_call: true
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      instance = action.send(:new, person: klass.new(name: "Alice", ssn: "111-11-1111"))
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:person]).to eq("[FILTERED]")
    end

    it "masks a class-backed shape value wholesale in inspect" do
      klass = person
      action = build_axn do
        expects :person, type: klass do
          field :name, method_call: true
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      inspected = inbound_facade(action.call(person: klass.new(name: "Alice", ssn: "111-11-1111")).__action__).inspect

      expect(inspected).to include("[FILTERED]")
      expect(inspected).not_to include("111-11-1111")
      # Over-redaction: the non-sensitive sibling is hidden too, because the object can't be filtered per-key.
      expect(inspected).not_to include("Alice")
    end

    it "masks only a malformed (non-Hash) element, leaving valid Hash elements filtered per-member" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, sensitive: true
          field :name
        end

        def call; end
      end

      instance = action.send(:new, items: [{ ssn: "111-11-1111", name: "Alice" }, person.new(name: "Bob", ssn: "222-22-2222")])
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:items]).to eq([{ ssn: "[FILTERED]", name: "Alice" }, "[FILTERED]"])
    end

    it "masks an object-backed value under a class shape declared on a subfield" do
      klass = person
      action = build_axn do
        expects :payload, type: Hash
        expects :person, on: :payload, type: klass, method_call: true do
          field :name, method_call: true
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      inputs = action.send(:new, payload: { person: klass.new(name: "Alice", ssn: "111-11-1111") }).send(:inputs_for_logging)
      expect(inputs[:payload][:person]).to eq("[FILTERED]")
    end

    it "filters a Hash value per-member under a Hash shape declared on a subfield" do
      action = build_axn do
        expects :payload, type: Hash
        expects :person, on: :payload, type: Hash do
          field :name
          field :ssn, sensitive: true
        end

        def call; end
      end

      inputs = action.send(:new, payload: { person: { name: "Alice", ssn: "111-11-1111" } }).send(:inputs_for_logging)
      expect(inputs[:payload][:person]).to eq({ name: "Alice", ssn: "[FILTERED]" })
    end

    it "masks an object-backed PARENT on a subfield-shape path (can't descend into it)" do
      person_klass = person
      payload_klass = Data.define(:person)
      action = build_axn do
        expects :payload, type: payload_klass
        expects :person, on: :payload, method_call: true, type: person_klass do
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      inputs = action.send(:new, payload: payload_klass.new(person: person_klass.new(name: "A", ssn: "111-11-1111"))).send(:inputs_for_logging)
      expect(inputs[:payload]).to eq("[FILTERED]")
    end

    it "does not falsely mask a Hash parent when the sensitive subfield key is absent" do
      person_klass = person
      action = build_axn do
        expects :payload, type: Hash
        expects :person, on: :payload, method_call: true, type: person_klass do
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      inputs = action.send(:new, payload: { other: "x" }).send(:inputs_for_logging)
      expect(inputs[:payload]).to eq({ other: "x" })
    end

    it "masks a nested object member regardless of symbol/string key form on either side" do
      klass = person
      # symbol member name × string data key
      sym_member = build_axn do
        expects :order, type: Hash do
          field :customer, type: klass, method_call: true do
            field :ssn, method_call: true, sensitive: true
          end
        end

        def call; end
      end
      inputs = sym_member.send(:new, order: { "customer" => klass.new(name: "Z", ssn: "999-99-9999") }).send(:inputs_for_logging)
      expect(inputs[:order]["customer"]).to eq("[FILTERED]")

      # string member name × symbol data key (the mirror combination)
      str_member = build_axn do
        expects :order, type: Hash do
          field "customer", type: klass, method_call: true do
            field :ssn, method_call: true, sensitive: true
          end
        end

        def call; end
      end
      inputs2 = str_member.send(:new, order: { customer: klass.new(name: "Z", ssn: "999-99-9999") }).send(:inputs_for_logging)
      expect(inputs2[:order][:customer]).to eq("[FILTERED]")

      # Both key forms present in the same Hash → every form masked (extraction reads symbol-first, but
      # the string form is still logged), so neither can leak.
      inputs3 = str_member.send(:new,
                                order: { "customer" => klass.new(name: "S", ssn: "str"), customer: klass.new(name: "Y", ssn: "sym") }).send(:inputs_for_logging)
      expect(inputs3[:order]).to eq({ "customer" => "[FILTERED]", customer: "[FILTERED]" })
    end

    it "masks a malformed Array supplied to a Hash shape wholesale (not element-mapped)" do
      action = build_axn do
        expects :payload, type: Hash do
          field :ssn, sensitive: true
        end

        def call; end
      end

      # Array is malformed for a Hash shape; its arbitrary contents (undeclared `note`) must not leak by
      # being treated as array elements with only `ssn` keys filtered.
      inputs = action.send(:new, payload: [{ note: "secret", ssn: "111" }]).send(:inputs_for_logging)
      expect(inputs[:payload]).to eq("[FILTERED]")
    end

    it "masks a malformed Hash supplied to an Array shape wholesale (not treated as one element)" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, sensitive: true
        end

        def call; end
      end

      # Hash is malformed for an Array shape; an undeclared sibling key must not leak by treating the
      # Hash as a single element with only `ssn` filtered.
      inputs = action.send(:new, items: { note: "secret", ssn: "111" }).send(:inputs_for_logging)
      expect(inputs[:items]).to eq("[FILTERED]")
    end

    it "masks a malformed Hash supplied to a class shape wholesale" do
      klass = person
      action = build_axn do
        expects :person, type: klass do
          field :ssn, method_call: true, sensitive: true
        end

        def call; end
      end

      inputs = action.send(:new, person: { note: "secret", ssn: "111" }).send(:inputs_for_logging)
      expect(inputs[:person]).to eq("[FILTERED]")
    end

    it "preserves a nil shaped value (valid absent data) rather than masking it" do
      action = build_axn do
        expects :payload, type: Hash, allow_nil: true do
          field :ssn, sensitive: true
        end

        def call; end
      end

      instance = action.send(:new, payload: nil)
      expect(instance.send(:inputs_for_logging)[:payload]).to be_nil
      expect(instance.execution_context[:inputs][:payload]).to be_nil
    end

    it "preserves nil elements but masks malformed scalar/object elements (a scalar may BE the secret)" do
      action = build_axn do
        expects :items, type: Array do
          field :ssn, sensitive: true
          field :name
        end

        def call; end
      end

      # A caller could mis-supply the raw sensitive value as the element (items: ["111-11-1111"]), so a
      # non-nil scalar in a member-bearing position is masked; nil (valid absent) is preserved; a Hash
      # filters per-member; an object masks wholesale.
      instance = action.send(:new, items: [{ ssn: "1", name: "A" }, nil, "111-11-1111", person.new(name: "B", ssn: "2")])
      expect(instance.send(:inputs_for_logging)[:items]).to eq([{ ssn: "[FILTERED]", name: "A" }, nil, "[FILTERED]", "[FILTERED]"])
    end

    it "does NOT redact an object-backed shape whose members are all non-sensitive" do
      klass = person
      action = build_axn do
        expects :person, type: klass do
          field :name, method_call: true
          field :ssn, method_call: true
        end

        def call; end
      end

      instance = action.send(:new, person: klass.new(name: "Alice", ssn: "111-11-1111"))

      # No sensitive member → the record is never in the redaction set → logged in full.
      expect(instance.send(:inputs_for_logging)[:person]).to eq(klass.new(name: "Alice", ssn: "111-11-1111"))
    end
  end

  # The walk down a subfield's wire path consumes a segment per Hash level (so it terminates), but maps
  # across an Array with the path UNCHANGED — which recursed until the stack blew on a self-referential
  # array in an intermediate position.
  describe "a self-referential value on the path to a sensitive member" do
    it "masks the cycle wholesale and still redacts the member it could reach" do
      action = build_axn do
        expects :orders
        expects :person, on: :orders, type: Hash do
          field :ssn, type: String, sensitive: true
        end
      end

      cyclic = [{ person: { ssn: "111-11-1111" } }]
      cyclic << cyclic

      # The revisited array masks rather than rendering a `[...]` placeholder: this walk returns DATA,
      # and we cannot descend to redact whatever sensitive member is nested inside — the same
      # over-redact-rather-than-leak call the opaque-value branch makes.
      expect(action.send(:new, orders: cyclic).send(:inputs_for_logging)[:orders])
        .to eq([{ person: { ssn: "[FILTERED]" } }, "[FILTERED]"])
    end
  end

  describe "model: on a shape member" do
    it "is rejected (reader-less members cannot resolve an id or expose an _id companion)" do
      expect do
        build_axn do
          expects :items, type: Array do
            field :company, model: Struct.new(:id)
          end
        end
      end.to raise_error(ArgumentError, /does not support model:/)
    end
  end

  # PRO-3166: a container's contents now live in the `of:` bag, so a `sensitive:` member declared inside a
  # bag's `shape:` sits on an edge the redaction walks did not descend — the declaration was accepted and the
  # value printed in the clear. Every walk that reaches a shape member reaches this one too.
  describe "a sensitive member inside a container's contents (of:)" do
    def sensitive_shape
      { members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: { type: { klass: String } }, sensitive: true),
                  Axn::Core::Contract::ShapeConfig.new(field: :name, validations: { type: { klass: String } })] }
    end

    # The regression this task exists for: the bag-shape spelling below and the field-level `shape:` spelling
    # beside it declare the same sensitive member, so they must log the same masked line.
    it "masks a sensitive member declared in an Array element's bag, exactly as a field-level shape does" do
      shape = sensitive_shape
      bagged = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }
      field_level = build_axn do
        expects :row, type: Hash do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end
      end

      bag_inputs = bagged.send(:new, rows: [{ ssn: "111-22-3333", name: "Ada" }]).send(:inputs_for_logging)
      field_inputs = field_level.send(:new, row: { ssn: "111-22-3333", name: "Ada" }).send(:inputs_for_logging)

      expect(field_inputs[:row]).to eq({ ssn: "[FILTERED]", name: "Ada" })
      expect(bag_inputs[:rows]).to eq([{ ssn: "[FILTERED]", name: "Ada" }])
    end

    it "contributes the bagged member's name to sensitive_fields (and not its sibling)" do
      shape = sensitive_shape
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      expect(action.sensitive_fields).to include(:ssn)
      expect(action.sensitive_fields).not_to include(:name)
    end

    it "masks the bagged member in inspect too" do
      shape = sensitive_shape
      action = build_axn do
        expects :rows, type: Array, of: { klass: Hash, shape: }

        def call; end
      end

      inspected = inbound_facade(action.call(rows: [{ ssn: "111-22-3333", name: "Ada" }]).__action__).inspect

      expect(inspected).not_to include("111-22-3333")
      expect(inspected).to include("[FILTERED]")
      expect(inspected).to include("Ada")
    end

    it "masks the member two containers down and leaves its sibling readable" do
      shape = sensitive_shape
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: } } }

      inputs = action.send(:new, m: [[{ ssn: "123-45-6789", name: "Ada" }]]).send(:inputs_for_logging)

      expect(inputs[:m]).to eq([[{ ssn: "[FILTERED]", name: "Ada" }]])
    end

    it "masks a sensitive member inside a map's values" do
      shape = sensitive_shape
      action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: } } }

      inputs = action.send(:new, m: { "acme" => { ssn: "123-45-6789", name: "Ada" } }).send(:inputs_for_logging)

      expect(inputs[:m]).to eq({ "acme" => { ssn: "[FILTERED]", name: "Ada" } })
    end

    # A member inside a map KEY is unreachable by name: a ParameterFilter reads a key only to decide about
    # its value and never descends into the key itself, so nothing behind this walk would catch it. The whole
    # map is masked rather than key-by-key, since distinct keys mask to the same thing and would collapse.
    it "masks the whole map when a sensitive member sits inside its keys" do
      shape = sensitive_shape
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: Hash, shape: }, values: Integer } }

      inputs = action.send(:new, m: { { ssn: "123-45-6789", name: "Ada" } => 1 }).send(:inputs_for_logging)

      expect(inputs[:m]).to eq("[FILTERED]")
    end

    # A shape MEMBER that is itself a container: the walk has to descend the member's own `of:` edge, not
    # only its `shape:`.
    it "masks a sensitive member inside a container declared on a shape member" do
      shape = sensitive_shape
      action = build_axn do
        expects :order, type: Hash do
          field :rows, type: Array, of: { klass: Hash, shape: }
          field :label, type: String
        end
      end

      inputs = action.send(:new, order: { rows: [{ ssn: "111-22-3333", name: "Ada" }], label: "q3" })
                     .send(:inputs_for_logging)

      expect(inputs[:order]).to eq({ rows: [{ ssn: "[FILTERED]", name: "Ada" }], label: "q3" })
    end

    # Opaque to ParameterFilter (it only descends Hashes), so the element is masked wholesale rather than
    # leaking the member nested inside it — the same over-redact-rather-than-leak call an object-backed
    # field-level shape gets.
    it "masks an element that is not a Hash wholesale, leaving valid siblings filtered per member" do
      shape = sensitive_shape
      person = Data.define(:name, :ssn)
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      inputs = action.send(:new, rows: [{ ssn: "111-22-3333", name: "Ada" }, person.new(name: "Bob", ssn: "222-22-2222")])
                     .send(:inputs_for_logging)

      expect(inputs[:rows]).to eq([{ ssn: "[FILTERED]", name: "Ada" }, "[FILTERED]"])
    end

    it "preserves a nil element (valid absent data) rather than masking it" do
      shape = sensitive_shape
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      inputs = action.send(:new, rows: [nil, { ssn: "111-22-3333", name: "Ada" }]).send(:inputs_for_logging)

      expect(inputs[:rows]).to eq([nil, { ssn: "[FILTERED]", name: "Ada" }])
    end

    # The flat distributing spelling stores the shape at the FIELD and an `of:` bag beside it; the bag
    # carries no contents of its own, so the new descent must leave this path exactly as it was. (Task 9
    # canonicalizes the pair into the bag; this stays green either way, which is the point.)
    it "leaves the flat distributing shape beside a bare of: unchanged" do
      action = build_axn do
        expects :items, type: Array, of: Hash do
          field :ssn, type: String, sensitive: true
          field :name, type: String
        end
      end

      inputs = action.send(:new, items: [{ ssn: "111-22-3333", name: "Ada" }]).send(:inputs_for_logging)

      expect(inputs[:items]).to eq([{ ssn: "[FILTERED]", name: "Ada" }])
    end

    # The control that catches over-masking: a bag whose shape carries no `sensitive:` must not make the
    # mask descend at all.
    it "does not mask a bag shape with no sensitive member" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: { type: { klass: String } }),
                          Axn::Core::Contract::ShapeConfig.new(field: :name, validations: { type: { klass: String } })] }
      action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: } }

      inputs = action.send(:new, rows: [{ ssn: "111-22-3333", name: "Ada" }]).send(:inputs_for_logging)

      expect(inputs[:rows]).to eq([{ ssn: "111-22-3333", name: "Ada" }])
    end

    # A cycle cannot close through Arrays alone under a field-level shape (an element only recurses by being
    # a Hash), but nested containers make one: an Array of Arrays. The revisited container masks wholesale.
    it "masks a self-referential Array of Arrays wholesale rather than recursing" do
      shape = sensitive_shape
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: } } }

      cyclic = [[{ ssn: "111-22-3333", name: "Ada" }]]
      cyclic << cyclic

      masked = action.send(:new, m: cyclic).send(:inputs_for_logging)[:m]

      # Asserted element-wise, and the revisited one by class first: handing a still-cyclic actual to the
      # `eq` differ is what makes a regression here hang the suite rather than report it.
      expect(masked.last).to be_a(String)
      expect(masked.last).to eq("[FILTERED]")
      expect(masked.first).to eq([{ ssn: "[FILTERED]", name: "Ada" }])
    end

    # The mask composes a shape pass with a contents pass, and the shape pass hands the contents pass a
    # COPY (`_mask_shape_element` returns `element.dup`). Guarding that copy is guarding a fresh object, so
    # the ancestry chain breaks and nothing is ever recognised as revisited — the walk then terminates only
    # when the DECLARATION runs out, embedding the caller's still-cyclic Hash in what redaction hands the
    # logger. The guard has to key on the caller's own object at every rung.
    it "masks a cycle wholesale under a bag that also carries a shape:" do
      inner = { klass: Hash, shape: sensitive_shape }
      middle = { klass: Hash, shape: sensitive_shape, of: { values: inner } }
      outer = { klass: Hash, shape: sensitive_shape, of: { values: middle } }
      action = build_axn { expects :m, type: Hash, of: { values: outer } }

      cyclic = { ssn: "111-22-3333" }
      cyclic[:self] = cyclic

      masked = action.send(:new, m: { "a" => cyclic }).send(:inputs_for_logging)[:m]["a"]

      # By class first: an unguarded walk leaves the caller's own cyclic Hash here, and handing that to the
      # `eq` differ is what turns a regression into a hang.
      expect(masked[:self]).to be_a(String)
      expect(masked).to eq({ ssn: "[FILTERED]", self: "[FILTERED]" })
    end

    # An Array-container bag shape is refused at DECLARATION (`_reject_distributing_inner_shape!`: at a bag
    # position `container: Array` means "distribute over the elements" to `ShapeValidator`, which is a
    # contract nobody could read off the declaration) — but a config assigned onto the class passed no
    # declaration walk and carries whatever its author built, which is the reachability bar every other bound
    # in this file is justified on. The mask's Array branch is live for exactly those, so both cases below
    # hold their graph rather than declaring it.
    def held(field, validations)
      action = build_axn { expects field, optional: true }
      action.internal_field_configs = [
        Axn::Core::Contract::FieldConfig.new(field:, reader_as: field, validations:),
      ].freeze
      action
    end

    def array_container_shape = sensitive_shape.merge(container: Array)

    def hash_container_shape = sensitive_shape.merge(container: Hash)

    # The same guard one rung deeper, where the pre-mask value is the only thing that can carry it. An
    # Array-container bag shape REPLACES each element with a copy (`_mask_shape_value` maps
    # `_mask_shape_element` over them), so the rung below it is the one place where the masked child is not
    # the caller's own object — and pairing the child with the copy rather than the original delays cycle
    # detection by a rung, expanding the caller's cyclic Hash one extra level into the log.
    it "keeps the cycle guard on the caller's object below an Array-container bag shape" do
      terminal = { klass: Hash, container: Hash, shape: hash_container_shape }
      third = { klass: Hash, container: Hash, shape: hash_container_shape, of: { values: terminal, container: Hash } }
      second = { klass: Hash, container: Array, shape: hash_container_shape, of: { values: third, container: Hash } }
      first = { klass: Array, container: Array, shape: array_container_shape, of: second }
      action = held(:m, { type: { klass: Array }, of: first })

      cyclic = { ssn: "111-22-3333", name: "Ada" }
      cyclic[:self] = cyclic

      masked = action.send(:new, m: [[cyclic]]).send(:inputs_for_logging)[:m][0][0]

      expect(masked[:self]).to be_a(String)
      expect(masked[:self]).to eq("[FILTERED]")
    end

    # `container: Array` on a bag's shape means "members read off each element of that inner Array" —
    # `ShapeValidator` distributes them exactly as it does for a field-level Array shape, and the mask has to
    # distribute with it. The content is an Array, so masking it as if it were a member-bearing Hash
    # over-redacts a whole rung that `_mask_shape_value` already knows how to descend.
    it "distributes a bag shape whose container is Array rather than masking the element wholesale" do
      action = held(:rows, { type: { klass: Array },
                             of: { klass: Array, container: Array, shape: array_container_shape } })

      inputs = action.send(:new, rows: [[{ ssn: "111-22-3333", name: "Ada" }]]).send(:inputs_for_logging)

      expect(inputs[:rows]).to eq([[{ ssn: "[FILTERED]", name: "Ada" }]])
    end

    # Task 6 exempts a key the shape names from the map contract (`additionalProperties` does not govern a
    # `properties` key), and this walk does not reproduce that exemption — matching it here would mean a
    # second copy of `OfValidator#exempt_key?`'s symbol/string matching, which is the duplication this
    # design exists to prevent. Pinned so that extracting the matcher later is a deliberate change.
    it "over-redacts a shape-named key that the map contract exempts" do
      values = { klass: Hash, shape: { members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: {}, sensitive: true)] } }
      action = build_axn do
        expects :metrics, type: Hash, of: { values: } do
          field :label, type: String
        end
      end

      inputs = action.send(:new, metrics: { label: "q3", visits: { ssn: "111-22-3333" } }).send(:inputs_for_logging)

      expect(inputs[:metrics]).to eq({ label: "[FILTERED]", visits: { ssn: "[FILTERED]" } })
    end

    # The collectors now recurse into members living inside an `of:` bag — members they never reached
    # before — so they read a member's `validations` on the terms every other read of a caller-supplied
    # member uses. A DECLARED graph is snapshotted into axn's own `ShapeConfig`s, so this only bites a
    # config assigned onto the class; that is the same route every other bound in this file exists for.
    it "reads a bagged member's validations without dispatching, so a hidden reader cannot skip the walk" do
      hidden = Class.new do
        def field = :inner

        def sensitive = false

        private

        def validations
          { type: { klass: Hash },
            shape: { container: Hash,
                     members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: {}, sensitive: true)] } }
        end
      end.new

      action = build_axn
      action.internal_field_configs = [
        Axn::Core::Contract::FieldConfig.new(
          field: :rows, reader_as: :rows,
          validations: { type: { klass: Array },
                         of: { klass: Hash, container: Array,
                               shape: { container: Hash, members: [hidden] } } }
        ),
      ].freeze

      expect(action.sensitive_fields).to include(:ssn)
      expect(action._sensitive_member_names(action.internal_field_configs.first, nil)).to include(:ssn)
    end

    it "resolves a dynamic sensitive: inside a bag against the instance" do
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: { type: { klass: String } },
                                                               sensitive: -> { redact })] }
      action = build_axn do
        expects :redact, type: :boolean, default: false
        expects :rows, type: Array, of: { klass: Hash, shape: }
      end

      expect(action.send(:new, redact: true, rows: [{ ssn: "111-22-3333" }]).send(:inputs_for_logging)[:rows])
        .to eq([{ ssn: "[FILTERED]" }])
      expect(action.send(:new, redact: false, rows: [{ ssn: "111-22-3333" }]).send(:inputs_for_logging)[:rows])
        .to eq([{ ssn: "111-22-3333" }])
    end
  end
end
