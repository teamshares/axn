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
