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

  # PRO-3072: a `sensitive:` Proc is `instance_exec`'d with NO arguments (it reads other fields by name,
  # the value is never handed to it) — so a Proc declaring a required parameter can never be called
  # successfully, and used to make `#inspect` raise on every resolution instead of failing at declaration.
  describe "sensitive: Proc arity" do
    let(:arity_error) { /sensitive: Proc is instance_exec'd against the action instance with no arguments/ }

    it "rejects a lambda with a required positional parameter" do
      expect { build_axn { expects :a, sensitive: ->(v) { v }, optional: true } }.to raise_error(ArgumentError, arity_error)
      expect { build_axn { expects :a, sensitive: ->(x, y) { x && y }, optional: true } }.to raise_error(ArgumentError, arity_error)
    end

    it "rejects a lambda with a required keyword parameter" do
      expect { build_axn { expects :a, sensitive: ->(k:) { k }, optional: true } }.to raise_error(ArgumentError, arity_error)
    end

    it "rejects a lambda mixing a required positional with an optional keyword" do
      # `arity` alone goes negative here (looks variadic-safe) despite `a` still being required —
      # this is the shape a plain `lambda? && arity.positive?` check would wave through.
      expect { build_axn { expects :a, sensitive: ->(x, k: nil) { x || k }, optional: true } }.to raise_error(ArgumentError, arity_error)
    end

    it "rejects a non-lambda proc with a required keyword" do
      # Non-lambda procs pad missing POSITIONAL args with nil, but still raise on a missing required
      # keyword — `lambda?` alone is not the right test.
      expect { build_axn { expects :a, sensitive: proc { |k:| k }, optional: true } }.to raise_error(ArgumentError, arity_error)
    end

    it "accepts every Proc shape callable with zero arguments" do
      callable_with_zero_args = [
        -> { true },
        ->(v = nil) { v.nil? },
        ->(*a) { a.empty? },
        ->(k: nil) { k.nil? },
        proc { |v| v.nil? }, # rubocop:disable Style/SymbolProc -- `&:nil?` changes arity/behavior on zero args
      ]
      callable_with_zero_args.each do |value|
        expect { build_axn { expects :a, sensitive: value, optional: true } }.not_to raise_error
      end
    end

    it "rejects a required-parameter Proc on a shape member too" do
      expect { build_axn { expects(:p, type: Hash, optional: true) { field :m, sensitive: ->(v) { v } } } }
        .to raise_error(ArgumentError, arity_error)
    end
  end

  # PRO-3072: the declaration guard cannot see everything — a Symbol naming a method that does not exist
  # yet, or one that takes a required argument, is still discovered only at resolution time. That path
  # must fail CLOSED (redact, warn) rather than raise, since it runs on `inspect`/logging/exception
  # reporting, which must never raise over a caller's `sensitive:` declaration.
  describe "sensitive: runtime resolution failures fail closed" do
    let(:warnings) { [] }

    def stub_warnings(action, warnings)
      allow_any_instance_of(action).to receive(:warn) { |_, msg| warnings << msg }
    end

    it "redacts and warns, rather than raising, when the named method takes a required argument" do
      action = build_axn do
        expects :ssn, sensitive: :broken_check
        exposes :other_field
        def call = expose(other_field: "visible")

        private

        def broken_check(_unexpected_arg) = true
      end
      stub_warnings(action, warnings)

      result = nil
      expect { result = action.call(ssn: "123-45-6789") }.not_to raise_error
      expect { result.inspect }.not_to raise_error
      expect(result.inspect).to include("other_field: \"visible\"")
      expect(warnings).to include(a_string_matching(/sensitive: :ssn \(:broken_check\) raised ArgumentError/))
    end

    it "redacts and warns, rather than raising, when the named method does not exist" do
      action = build_axn do
        expects :ssn, sensitive: :nonexistent_method
        def call = nil
      end
      stub_warnings(action, warnings)

      instance = action.send(:new, ssn: "123-45-6789")
      expect { instance.send(:inputs_for_logging) }.not_to raise_error
      expect(instance.send(:inputs_for_logging)[:ssn]).to eq("[FILTERED]")
      expect(warnings).to include(a_string_matching(/sensitive: :ssn \(:nonexistent_method\) raised NoMethodError/))
    end

    it "only redacts the field whose callable failed, leaving the rest of the payload intact" do
      action = build_axn do
        expects :ssn, sensitive: :broken_check
        expects :name

        def call = nil

        private

        def broken_check(_unexpected_arg) = true
      end
      stub_warnings(action, warnings)

      instance = action.send(:new, ssn: "123-45-6789", name: "Ada")
      inputs = instance.send(:inputs_for_logging)

      expect(inputs[:ssn]).to eq("[FILTERED]")
      expect(inputs[:name]).to eq("Ada")
    end

    it "fails closed (redacts) rather than open when resolution raises" do
      action = build_axn do
        expects :ssn, sensitive: :broken_check
        def call = nil

        private

        # Would be non-sensitive if it could ever run — but it can't, so this exercises the fail-closed default.
        def broken_check(_unexpected_arg) = false
      end
      stub_warnings(action, warnings)

      instance = action.send(:new, ssn: "123-45-6789")
      expect(instance.send(:inputs_for_logging)[:ssn]).to eq("[FILTERED]")
    end

    # The warning is a diagnostic ABOUT the fail-closed decision, not part of it: a broken warn target
    # (a custom logger raising — closed IO, a timed-out network sink) must not undo `true` having already
    # been earned. Without the inner rescue, this raises straight through `inputs_for_logging`, defeating
    # the very guarantee this whole path exists to provide.
    it "still redacts when the warning itself raises (a broken logger must not undo fail-closed)" do
      action = build_axn do
        expects :ssn, sensitive: :broken_check
        def call = nil

        private

        def broken_check(_unexpected_arg) = true
      end
      allow_any_instance_of(action).to receive(:warn).and_raise(IOError, "closed stream")

      instance = action.send(:new, ssn: "123-45-6789")
      result = nil
      expect { result = instance.send(:inputs_for_logging) }.not_to raise_error
      expect(result[:ssn]).to eq("[FILTERED]")
    end

    # A `sensitive:` predicate exists to keep some value out of logs — so a predicate that raises with
    # that value embedded in its own exception message must not have the warning re-print it. Only the
    # exception's CLASS and source location are rendered, never its `#message`.
    it "never renders the raised exception's own message, which may itself embed the value being protected" do
      action = build_axn do
        expects :ssn
        exposes :secret, sensitive: ->(*) { raise "leaked value: 123-45-6789" }
        def call = expose(secret: "hidden")
      end
      stub_warnings(action, warnings)

      result = action.call(ssn: "irrelevant")
      expect(result.inspect).not_to include("123-45-6789")
      expect(warnings.join).not_to include("123-45-6789")
      expect(warnings).to include(a_string_matching(/sensitive: :secret \(.+\) raised RuntimeError at /))
    end

    # A Proc CAN carry a singleton `inspect` (a Symbol cannot — `define_singleton_method` on one raises
    # TypeError), and this predicate is the one already known to misbehave, having just raised. Naming it
    # must not dispatch to it: an author's own weaponized `inspect` could otherwise smuggle a captured
    # secret into the warning under cover of "describing the rule that failed".
    it "never dispatches to the failed predicate's own #inspect when naming it in the warning" do
      hostile = ->(*) { raise "boom" }
      hostile.define_singleton_method(:inspect) { "leaked: 123-45-6789" }

      action = build_axn do
        expects :ssn
        exposes :secret, sensitive: hostile
        def call = expose(secret: "hidden")
      end
      stub_warnings(action, warnings)

      result = action.call(ssn: "irrelevant")
      expect(result.inspect).not_to include("123-45-6789")
      expect(warnings.join).not_to include("123-45-6789")
      expect(warnings).to include(a_string_matching(/sensitive: :secret \(#<Proc.*\) raised RuntimeError at /))
    end
  end

  # PRO-3072 (Codex follow-up): the declaration-time arity guard reads a caller-supplied Proc's own
  # `#parameters` to decide whether it can be called with zero arguments — so a Proc lying about its own
  # metadata could sail a genuinely required-argument predicate straight past the guard it exists to enforce.
  describe "sensitive: Proc arity guard resists a lying #parameters" do
    it "still rejects a required-argument lambda whose #parameters claims to take none" do
      lying = ->(v) { v }
      lying.define_singleton_method(:parameters) { [] }

      expect { build_axn { expects :a, sensitive: lying, optional: true } }
        .to raise_error(ArgumentError, /sensitive: Proc is instance_exec'd against the action instance with no arguments/)
    end
  end

  # PRO-3072 (Codex follow-up, round 2): a Symbol cannot carry a per-instance singleton method, but
  # `Symbol#inspect` itself can still be overridden PROCESS-WIDE (reopening the class, or `prepend`). The
  # warning must survive that too, which is exactly why `PropertyNames` binds the native implementation at
  # load time rather than dispatching — a rebind captured before this spec ever runs.
  describe "sensitive: warning survives a process-wide Symbol#inspect override" do
    it "never renders a hijacked Symbol#inspect's fake output in the warning" do
      original_inspect = Symbol.instance_method(:inspect)
      Symbol.define_method(:inspect) { "leaked: 123-45-6789" }

      action = build_axn do
        expects :ssn, sensitive: :broken_check
        def call = nil

        private

        def broken_check(_unexpected_arg) = true
      end
      warnings = []
      allow_any_instance_of(action).to receive(:warn) { |_, msg| warnings << msg }

      instance = action.send(:new, ssn: "123-45-6789")
      result = instance.send(:inputs_for_logging)

      expect(result[:ssn]).to eq("[FILTERED]")
      expect(warnings.join).not_to include("leaked: 123-45-6789")
    ensure
      Symbol.define_method(:inspect, original_inspect)
    end
  end
end
