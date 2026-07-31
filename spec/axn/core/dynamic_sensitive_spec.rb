# frozen_string_literal: true

RSpec.describe "Dynamic sensitive fields" do
  describe "exposes with callable sensitive" do
    context "with a proc" do
      let(:action) do
        build_axn do
          expects :redact_mode, type: :boolean, default: false

          exposes :public_data
          exposes :secret_data, sensitive: -> { redact_mode }

          def call
            expose public_data: "visible"
            expose secret_data: "hidden-value"
          end
        end
      end

      context "when redact_mode is true" do
        subject { action.call(redact_mode: true) }

        it "filters the sensitive field in inspect" do
          expect(subject.inspect).to include("secret_data: [FILTERED]")
          expect(subject.inspect).to include("public_data: \"visible\"")
        end

        it "filters the sensitive field in outputs_for_logging" do
          instance = action.send(:new, redact_mode: true)
          instance.call
          outputs = instance.send(:outputs_for_logging)

          expect(outputs[:secret_data]).to eq("[FILTERED]")
          expect(outputs[:public_data]).to eq("visible")
        end
      end

      context "when redact_mode is false" do
        subject { action.call(redact_mode: false) }

        it "does not filter the field in inspect" do
          expect(subject.inspect).to include("secret_data: \"hidden-value\"")
          expect(subject.inspect).to include("public_data: \"visible\"")
        end

        it "does not filter the field in outputs_for_logging" do
          instance = action.send(:new, redact_mode: false)
          instance.call
          outputs = instance.send(:outputs_for_logging)

          expect(outputs[:secret_data]).to eq("hidden-value")
          expect(outputs[:public_data]).to eq("visible")
        end
      end
    end

    context "with a symbol referencing an instance method" do
      let(:action) do
        build_axn do
          expects :user_role, type: String

          exposes :admin_details, sensitive: :hide_admin_details?

          def call
            expose admin_details: "admin-secret-info"
          end

          private

          def hide_admin_details?
            user_role != "admin"
          end
        end
      end

      context "when user is admin" do
        subject { action.call(user_role: "admin") }

        it "does not filter the field" do
          expect(subject.inspect).to include("admin_details: \"admin-secret-info\"")
        end
      end

      context "when user is not admin" do
        subject { action.call(user_role: "guest") }

        it "filters the field" do
          expect(subject.inspect).to include("admin_details: [FILTERED]")
        end
      end
    end
  end

  describe "expects with callable sensitive" do
    let(:action) do
      build_axn do
        expects :include_pii, type: :boolean, default: false
        expects :ssn, sensitive: -> { !include_pii }

        exposes :processed

        def call
          expose processed: "done"
        end
      end
    end

    context "when include_pii is false (default)" do
      it "filters ssn in inputs_for_logging" do
        instance = action.send(:new, ssn: "123-45-6789")
        outputs = instance.send(:inputs_for_logging)

        expect(outputs[:ssn]).to eq("[FILTERED]")
      end

      it "filters ssn in internal_context inspect" do
        result = action.call(ssn: "123-45-6789")
        expect(result.__action__.internal_context.inspect).to include("ssn: [FILTERED]")
      end
    end

    context "when include_pii is true" do
      it "does not filter ssn in inputs_for_logging" do
        instance = action.send(:new, include_pii: true, ssn: "123-45-6789")
        outputs = instance.send(:inputs_for_logging)

        expect(outputs[:ssn]).to eq("123-45-6789")
      end
    end
  end

  describe "mixed static and dynamic sensitive fields" do
    let(:action) do
      build_axn do
        expects :verbose_mode, type: :boolean, default: false

        exposes :always_hidden, sensitive: true
        exposes :conditionally_hidden, sensitive: -> { !verbose_mode }
        exposes :never_hidden

        def call
          expose always_hidden: "secret1"
          expose conditionally_hidden: "secret2"
          expose never_hidden: "public"
        end
      end
    end

    context "when verbose_mode is false" do
      subject { action.call(verbose_mode: false) }

      it "filters both sensitive fields" do
        expect(subject.inspect).to include("always_hidden: [FILTERED]")
        expect(subject.inspect).to include("conditionally_hidden: [FILTERED]")
        expect(subject.inspect).to include("never_hidden: \"public\"")
      end
    end

    context "when verbose_mode is true" do
      subject { action.call(verbose_mode: true) }

      it "still filters static sensitive but not dynamic" do
        expect(subject.inspect).to include("always_hidden: [FILTERED]")
        expect(subject.inspect).to include("conditionally_hidden: \"secret2\"")
        expect(subject.inspect).to include("never_hidden: \"public\"")
      end
    end
  end

  describe "subfields with callable sensitive" do
    let(:action) do
      build_axn do
        expects :redact_password, type: :boolean, default: true
        expects :user_data, type: Hash
        expects :password, on: :user_data, sensitive: -> { redact_password }
        expects :email, on: :user_data

        def call; end
      end
    end

    let(:user_data) { { email: "user@example.com", password: "secret123" } }

    context "when redact_password is true" do
      it "filters the password subfield in inputs_for_logging" do
        instance = action.send(:new, user_data:, redact_password: true)
        inputs = instance.send(:inputs_for_logging)

        expect(inputs[:user_data][:password]).to eq("[FILTERED]")
        expect(inputs[:user_data][:email]).to eq("user@example.com")
      end
    end

    context "when redact_password is false" do
      it "does not filter the password subfield" do
        instance = action.send(:new, user_data:, redact_password: false)
        inputs = instance.send(:inputs_for_logging)

        expect(inputs[:user_data][:password]).to eq("secret123")
        expect(inputs[:user_data][:email]).to eq("user@example.com")
      end
    end
  end

  describe "class-level methods" do
    let(:action) do
      build_axn do
        expects :mode
        exposes :data, sensitive: -> { mode == "secret" }
      end
    end

    describe "._has_dynamic_sensitive_fields?" do
      it "returns true when there are callable sensitive fields" do
        expect(action._has_dynamic_sensitive_fields?).to be true
      end

      it "returns false when all sensitive fields are static" do
        static_action = build_axn do
          expects :input, sensitive: true
          exposes :output, sensitive: false
        end
        expect(static_action._has_dynamic_sensitive_fields?).to be false
      end
    end

    describe ".sensitive_fields (static)" do
      it "only returns statically sensitive fields" do
        mixed_action = build_axn do
          expects :static_sensitive, sensitive: true
          expects :dynamic_sensitive, sensitive: -> { true }
          expects :not_sensitive
        end

        expect(mixed_action.sensitive_fields).to eq([:static_sensitive])
      end

      it "also redacts the generated <field>_id alias for a sensitive model: field" do
        company_klass = Struct.new(:id) do
          def self.find(_id) = new
        end

        model_action = build_axn do
          expects :company, model: { klass: company_klass, finder: :find }, sensitive: true
        end

        expect(model_action.sensitive_fields).to include(:company, :company_id)
      end

      it "does not add a spurious _id key for a sensitive non-model field" do
        plain_action = build_axn do
          expects :ssn, sensitive: true
        end

        expect(plain_action.sensitive_fields).to eq([:ssn])
      end
    end

    describe "._resolve_sensitive_fields" do
      it "resolves callable sensitive values against the action instance" do
        instance = action.send(:new, mode: "secret")
        resolved = action.send(:_resolve_sensitive_fields, instance)
        expect(resolved).to include(:data)
      end

      it "returns empty when callable evaluates to false" do
        instance = action.send(:new, mode: "public")
        resolved = action.send(:_resolve_sensitive_fields, instance)
        expect(resolved).not_to include(:data)
      end
    end
  end

  describe "execution_context integration" do
    let(:action) do
      build_axn do
        expects :hide_output, type: :boolean, default: false

        exposes :output, sensitive: -> { hide_output }

        def call
          expose output: "sensitive-data"
        end
      end
    end

    it "uses dynamic filtering in execution_context" do
      instance = action.send(:new, hide_output: true)
      instance.call
      ctx = instance.execution_context

      expect(ctx[:outputs][:output]).to eq("[FILTERED]")
    end

    it "does not filter when dynamic condition is false" do
      instance = action.send(:new, hide_output: false)
      instance.call
      ctx = instance.execution_context

      expect(ctx[:outputs][:output]).to eq("sensitive-data")
    end
  end

  # What redaction can derive from the DECLARATION is derived once per contract, so a logged call's cost does
  # not scale with the stored shape graph. Everything here pins the two ways that can go wrong: an answer
  # outliving the contract it was derived from, and an answer being reused where it depends on the instance.
  describe "facts reused across calls" do
    def logged(klass, data, instance = klass.send(:new))
      klass._context_slice(data:, direction: :inbound, action_instance: instance)
    end

    # A contract can grow after it has been logged: a reopened class, a subclass, a `Mountable` builder. The
    # derived answers are keyed on the IDENTITY of the config arrays, which declaration replaces, so a grown
    # contract misses rather than answering from the old one. `inspection_filter` had exactly this bug before
    # the memo was keyed that way: a field declared `sensitive:` after the first logged call was logged in the
    # clear, forever.
    it "redacts a sensitive field declared after the first logged call" do
      klass = build_axn { expects :a, optional: true }
      expect(logged(klass, { a: "1" })).to eq({ a: "1" })

      klass.class_eval { expects :b, sensitive: true, optional: true }

      expect(logged(klass, { a: "1", b: "s3cr3t" })).to eq({ a: "1", b: "[FILTERED]" })
      expect(klass.sensitive_fields).to eq([:b])
      expect(klass.inspection_filter.filter({ b: "s3cr3t" })).to eq({ b: "[FILTERED]" })
    end

    it "redacts a sensitive shape member declared after the first logged call" do
      klass = build_axn { expects(:p, type: Hash) { field :m, type: String } }
      expect(logged(klass, { p: { m: "1" } })).to eq({ p: { m: "1" } })

      klass.class_eval { expects(:q, type: Hash) { field :ssn, type: String, sensitive: true } }

      expect(logged(klass, { p: { m: "1" }, q: { ssn: "9", other: "x" } }))
        .to eq({ p: { m: "1" }, q: { ssn: "[FILTERED]", other: "x" } })
      # The shaped value may also be a non-Hash the key filter cannot descend into, which is masked wholesale
      # off the derived shape paths rather than the field-name set.
      expect(logged(klass, { q: "opaque" })).to eq({ q: "[FILTERED]" })
    end

    it "starts resolving per instance once a dynamic sensitive: is declared after a static contract" do
      klass = build_axn { expects :a, optional: true }
      expect(logged(klass, { a: "1" })).to eq({ a: "1" })

      klass.class_eval do
        expects :flag, type: :boolean, optional: true
        expects :secret, sensitive: :flag, optional: true
      end

      expect(logged(klass, { flag: true, secret: "s" }, klass.send(:new, flag: true))).to eq({ flag: true, secret: "[FILTERED]" })
      expect(logged(klass, { flag: false, secret: "s" }, klass.send(:new, flag: false))).to eq({ flag: false, secret: "s" })
    end

    # A subclass that declares nothing of its own READS the superclass's config arrays, so it derives the same
    # answers — and when the superclass's contract later grows, the subclass's derivation has to fall out of date
    # along with it. A subclass that declares its own `sensitive:` mints its own arrays and never reaches back
    # into the parent's answer.
    it "re-derives for a subclass when the superclass's contract grows" do
      parent = build_axn { expects :a, optional: true }
      plain_child = Class.new(parent)
      expect(logged(plain_child, { a: "1" })).to eq({ a: "1" })

      own_child = Class.new(parent) { expects :b, sensitive: true, optional: true }
      expect(logged(own_child, { a: "1", b: "s" })).to eq({ a: "1", b: "[FILTERED]" })
      expect(parent.sensitive_fields).to eq([])

      parent.class_eval { expects :c, sensitive: true, optional: true }

      expect(logged(plain_child, { a: "1", c: "s" })).to eq({ a: "1", c: "[FILTERED]" })
    end

    # A dynamic `sensitive:` is resolved per instance, in BOTH orders: an answer cached from the first instance
    # to call would over-redact for the next one, which looks safe and is still a behavior change. Both
    # mechanisms are exercised, because they are reached differently — a Hash member is redacted by key name,
    # while a NON-Hash value in a member-bearing position can only be masked off the resolved shape paths.
    it "resolves a dynamic sensitive: per instance, whichever instance calls first" do
      klass = build_axn do
        expects :flag, type: :boolean, optional: true
        expects :payload, type: Hash, optional: true do
          field :ssn, type: String, sensitive: :flag
        end
      end
      data = { payload: { ssn: "9", other: "x" } }

      expect(logged(klass, data.merge(flag: false), klass.send(:new, flag: false))).to eq({ flag: false, payload: { ssn: "9", other: "x" } })
      expect(logged(klass, data.merge(flag: true), klass.send(:new, flag: true))).to eq({ flag: true, payload: { ssn: "[FILTERED]", other: "x" } })
      expect(logged(klass, data.merge(flag: false), klass.send(:new, flag: false))).to eq({ flag: false, payload: { ssn: "9", other: "x" } })

      expect(logged(klass, { flag: true, payload: "opaque" }, klass.send(:new, flag: true))).to eq({ flag: true, payload: "[FILTERED]" })
      expect(logged(klass, { flag: false, payload: "opaque" }, klass.send(:new, flag: false))).to eq({ flag: false, payload: "opaque" })
    end

    # Reusing an answer is gated on ONE question — does resolving need the instance — and that is only a single
    # question because the value space is closed at declaration. A value outside the grammar would resolve
    # differently depending on which path asked (the per-instance path truthiness-tests it, the instanceless one
    # counts only a literal `true`), and it can no longer be declared at all.
    it "needs an instance exactly when a sensitive: is a Proc or a Symbol" do
      expect(build_axn { expects :a, sensitive: true, optional: true }._has_dynamic_sensitive_fields?).to be false
      expect(build_axn { expects :a, sensitive: nil, optional: true }._has_dynamic_sensitive_fields?).to be false
      expect(build_axn { expects :a, sensitive: :flag, optional: true }._has_dynamic_sensitive_fields?).to be true
      expect(build_axn { expects :a, sensitive: -> { true }, optional: true }._has_dynamic_sensitive_fields?).to be true
    end
  end

  # A `sensitive:` value that is not a resolution rule fails at DECLARATION, because its runtime failure mode is
  # a leak rather than an error: a truthy non-rule (`sensitive: "yes"`, `sensitive: 1`) left the field out of the
  # name-based redaction set and logged the secret in the clear, with no signal to the author.
  describe "the sensitive: grammar" do
    let(:grammar_error) { /sensitive: must be true, false, a Symbol naming an action method, or a Proc/ }
    let(:accepted) { [true, false, nil, :flag, -> { true }] }

    it "accepts every value that is a resolution rule, on a field and on a shape member" do
      accepted.each do |value|
        expect { build_axn { expects :a, sensitive: value, optional: true } }.not_to raise_error
        expect { build_axn { exposes :b, sensitive: value, optional: true } }.not_to raise_error
        expect { build_axn { expects(:p, type: Hash, optional: true) { field :m, sensitive: value } } }.not_to raise_error
      end
    end

    # Named by CLASS, never by the offender's own `inspect` — that is caller code running while its error is
    # built, and one raising outside StandardError would escape class definition entirely.
    it "rejects a value that is not, naming its class" do
      expect { build_axn { expects :a, sensitive: "yes", optional: true } }
        .to raise_error(ArgumentError, /#{grammar_error}.*got a value of class String/m)
      expect { build_axn { expects :a, sensitive: 1, optional: true } }.to raise_error(ArgumentError, grammar_error)
      # A callable that is not a Proc would be truthiness-tested, i.e. always sensitive — not the rule it looks like.
      expect { build_axn { expects :a, sensitive: Object.new.tap { |o| o.define_singleton_method(:call) { true } }, optional: true } }
        .to raise_error(ArgumentError, grammar_error)
    end

    it "rejects it at every place sensitive: is accepted" do
      expect { build_axn { exposes :a, sensitive: "yes" } }.to raise_error(ArgumentError, grammar_error)
      expect do
        build_axn do
          expects :parent, type: Hash, optional: true
          expects :a, on: :parent, sensitive: "yes", optional: true
        end
      end.to raise_error(ArgumentError, grammar_error)
      expect { build_axn { expects :a, on: :ambient_context, sensitive: "yes", optional: true } }
        .to raise_error(ArgumentError, grammar_error)
      expect { build_axn { expects(:p, type: Hash, optional: true) { field :m, sensitive: "yes" } } }
        .to raise_error(ArgumentError, grammar_error)
    end

    # A rejected declaration must leave nothing behind — the guard runs inside the config constructor, before
    # the class-level arrays are replaced.
    it "leaves the class carrying no config for the rejected field" do
      klass = build_axn { expects :ok, optional: true }
      expect { klass.class_eval { expects :bad, sensitive: "yes", optional: true } }.to raise_error(ArgumentError, grammar_error)

      expect(klass.internal_field_configs.map(&:field)).to eq([:ok])
      expect(klass.send(:new, ok: "1")).not_to respond_to(:bad)
    end

    # `nil` is accepted as `false` so `sensitive: some_flag` reads naturally when the flag is unset — and it
    # really does behave as false rather than as "unset, therefore dynamic".
    it "treats nil as false rather than as a rule needing an instance" do
      klass = build_axn { expects :secret, sensitive: nil, optional: true }

      expect(klass.sensitive_fields).to eq([])
      expect(klass._context_slice(data: { secret: "SECRET" }, direction: :inbound, action_instance: klass.send(:new)))
        .to eq({ secret: "SECRET" })
    end
  end
end
