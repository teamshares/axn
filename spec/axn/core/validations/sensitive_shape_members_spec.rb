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

      inspected = action.call(items: [{ ssn: "111-11-1111", name: "Alice" }]).__action__.internal_context.inspect

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

      inspected = action.call(payload: { token: "s3cr3t", user: "alice" }).__action__.internal_context.inspect

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

      inspected = action.call(order: { customer: { ssn: "999-99-9999" } }).__action__.internal_context.inspect

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

      inspected = action.call(items: [{ ssn: "111-11-1111", name: "Alice" }]).__action__.internal_context.inspect

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

      inspected = action.call(payload: { details: { token: "s3cr3t", user: "alice" } }).__action__.internal_context.inspect

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
        expects :items, type: Array, shape: { members: [member], container: Array }
      end

      expect { action.sensitive_fields }.not_to raise_error
      expect(action.sensitive_fields).to eq([])
    end

    it "does not raise from inspect for a member lacking #sensitive" do
      member = raw_member
      action = build_axn do
        expects :items, type: Array, shape: { members: [member], container: Array }

        def call; end
      end

      result = action.call(items: [{ name: "Alice" }])
      expect { result.__action__.internal_context.inspect }.not_to raise_error
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

      inspected = action.call(person: klass.new(name: "Alice", ssn: "111-11-1111")).__action__.internal_context.inspect

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
end
