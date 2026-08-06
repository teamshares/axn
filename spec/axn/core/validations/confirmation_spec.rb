# frozen_string_literal: true

RSpec.describe "confirmation:" do
  # Mirrors the inline `Class.new { include Axn; def call = nil }` idiom the rest of the suite uses.
  def build_axn(&declaration)
    Class.new do
      include Axn
      def call = nil
    end.tap { |klass| klass.class_eval(&declaration) }
  end

  describe "a declared pair at the top level" do
    let(:action) do
      build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
    end

    it "passes when the confirmation matches" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "fails when the confirmation does not match" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "compares the companion's transformed value, not its raw wire value" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true, preprocess: ->(s) { s&.strip }
      end
      expect(klass.call(password: "s3cret", password_confirmation: "  s3cret  ")).to be_ok
    end
  end

  describe "the implicit companion" do
    let(:action) { build_axn { expects :password, type: String, confirmation: true } }

    it "fails a mismatch with no companion declared by the author" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "passes a match with no companion declared by the author" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "inherits coerce: so both sides compare in the same space" do
      klass = build_axn { expects :count, coerce: Integer, confirmation: true }
      expect(klass.call(count: "5", count_confirmation: "5")).to be_ok
    end

    it "inherits preprocess: so both sides compare in the same space" do
      klass = build_axn { expects :name, type: String, preprocess: ->(s) { s&.strip }, confirmation: true }
      expect(klass.call(name: " kd ", name_confirmation: " kd ")).to be_ok
    end

    it "inherits sensitive: so a confirmed secret's companion is redacted too" do
      klass = build_axn { expects :password, type: String, sensitive: true, confirmation: true }
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

      expect(companion.sensitive).to be(true)

      logged = klass.send(:new, password: "s3cret", password_confirmation: "s3cret").send(:inputs_for_logging)
      expect(logged[:password_confirmation]).to eq("[FILTERED]")
    end

    it "does not inherit default:, which would satisfy its own comparison" do
      klass = build_axn { expects :password, type: String, default: "fallback", confirmation: true }
      expect(klass.call).not_to be_ok
    end

    it "names the reader off the aliased reader and the wire key off the field" do
      klass = build_axn { expects :password, as: :pw, type: String, confirmation: true }

      expect(klass.instance_methods).to include(:pw_confirmation)
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }
      expect(companion).not_to be_nil
      expect(companion.reader_as).to eq(:pw_confirmation)
    end

    it "stands down when the author declares the companion explicitly" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
      expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "stands down when the author declares the companion first" do
      klass = build_axn do
        expects :password_confirmation, type: String, optional: true
        expects :password, type: String, confirmation: true
      end
      expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
      expect(klass.internal_field_configs.count { |c| c.field == :password_confirmation }).to eq(1)
    end

    # The companion's own presence: true picks up allow_nil: true (the gate is on the DECLARATION, not
    # the type entry, so the type check remains the account of the nil) — its inherited type: still
    # rejects the nil, so an omitted companion still fails, with one clause rather than two.
    it "requires the companion once there is something to confirm" do
      result = action.call(password: "s3cret")
      expect(result).not_to be_ok
      expect(result.exception.message).to eq("Password confirmation is not a String")
    end

    it "does not require the companion when the base field is absent" do
      expect(action.call).not_to be_ok
      expect(action.call.exception.message).not_to include("Password confirmation")
    end

    # Requiredness is the companion's own `presence:`, not a side effect of the inherited `type:` — so a base
    # whose type accepts nil (or declares none at all) enforces its confirmation exactly as a strict one does.
    {
      # `proc`, not `->`: `build_axn` class_evals the block, which yields the class to it.
      "an untyped base" => proc { expects :password, confirmation: true },
      "an allow_nil: base" => proc { expects :password, type: String, allow_nil: true, confirmation: true },
      "an optional: base" => proc { expects :password, type: String, optional: true, confirmation: true },
    }.each do |label, declaration|
      context "with #{label}" do
        let(:klass) { build_axn(&declaration) }

        it "still requires the companion once the base is present" do
          result = klass.call(password: "s3cret")
          expect(result).not_to be_ok
          expect(result.exception.message).to include("Password confirmation can't be blank")
        end

        it "still compares the pair" do
          expect(klass.call(password: "s3cret", password_confirmation: "nope")).not_to be_ok
          expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
        end
      end
    end

    it "requires the companion on a subfield whose base declares no type" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, confirmation: true
      end
      expect(klass.call(payload: { password: "a" })).not_to be_ok
      expect(klass.call(payload: { password: "a", password_confirmation: "a" })).to be_ok
    end

    # The companion IS the line the author would otherwise have written — pinned as a whole rather than
    # option by option, so an inherited option that stops carrying shows up here even if no example names it.
    it "is exactly the declaration the author would have written by hand" do
      hand = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, if: :password
      end
      auto = build_axn { expects :password, type: String, confirmation: true }

      expect(auto.internal_field_configs.find { |c| c.field == :password_confirmation }.validations)
        .to eq(hand.internal_field_configs.find { |c| c.field == :password_confirmation }.validations)
      expect(auto.input_schema).to eq(hand.input_schema)
    end

    # A base that admits a blank value can hold one that is blank yet TRUTHY (`""`, `[]`, `{}`), where
    # "the base is truthy" and "the base has something to confirm" stop being the same question. Demanding a
    # (non-blank) companion there would be unsatisfiable — no non-blank value matches a blank base — so the
    # companion is not demanded, while a supplied one is still compared.
    describe "a base that admits a blank value" do
      shared_examples "a blank-admitting base" do |field:, blank:, present:, other:|
        it "does not demand a companion for a blank base" do
          expect(klass.call(field => blank)).to be_ok
        end

        it "accepts a companion that matches the blank base" do
          expect(klass.call(field => blank, :"#{field}_confirmation" => blank)).to be_ok
        end

        it "still rejects a companion that contradicts the blank base" do
          result = klass.call(field => blank, :"#{field}_confirmation" => other)
          expect(result).not_to be_ok
          expect(result.exception.message).to match(/confirmation doesn't match/)
        end

        it "still demands a companion once the base is present" do
          expect(klass.call(field => present)).not_to be_ok
          expect(klass.call(field => present, :"#{field}_confirmation" => present)).to be_ok
        end
      end

      # The three tolerance spellings are near-synonyms that push DIFFERENT halves (`optional:` pushes
      # allow_blank, `allow_nil:` pushes allow_nil), so any tolerance reaching the confirmation entry made
      # them answer the same input differently. None reaches it — a supplied companion is compared whatever
      # the base holds — so all three behave identically here.
      %i[optional allow_nil allow_blank].each do |tolerance|
        context "with #{tolerance}:" do
          let(:klass) { build_axn { expects :password, type: String, tolerance => true, confirmation: true } }

          it_behaves_like "a blank-admitting base", field: :password, blank: "", present: "s3cret", other: "nope"

          it "reports a companion supplied against an absent base as the mismatch it is" do
            expect(klass.call(password_confirmation: "nope")).not_to be_ok
            expect(klass.call(password: nil, password_confirmation: "nope")).not_to be_ok
          end

          it "asks nothing of a caller who supplies neither half" do
            expect(klass.call).to be_ok
          end
        end
      end

      context "with an untyped optional: base" do
        let(:klass) { build_axn { expects :password, optional: true, confirmation: true } }

        it_behaves_like "a blank-admitting base", field: :password, blank: "", present: "s3cret", other: "nope"
      end

      context "with allow_empty:" do
        let(:klass) { build_axn { expects :tags, type: Array, allow_empty: true, confirmation: true } }

        it_behaves_like "a blank-admitting base", field: :tags, blank: [], present: %w[a], other: %w[b]
      end

      context "with an explicit presence: false" do
        let(:klass) { build_axn { expects :password, type: String, presence: false, confirmation: true } }

        it_behaves_like "a blank-admitting base", field: :password, blank: "", present: "s3cret", other: "nope"
      end

      # `type: :boolean`/`:params` carry no presence check of their own (their validation logic stands in for
      # it), so they land in the same bucket — and their companions must still be enforced.
      context "with a :boolean base" do
        let(:klass) { build_axn { expects :flag, type: :boolean, allow_nil: true, confirmation: true } }

        it "demands a companion once the base is true" do
          expect(klass.call(flag: true)).not_to be_ok
          expect(klass.call(flag: true, flag_confirmation: true)).to be_ok
        end

        it "demands nothing for the falsey base a confirmation cannot be asked about" do
          expect(klass.call(flag: false)).to be_ok
          expect(klass.call(flag: nil)).to be_ok
        end

        it "still compares a companion supplied against a nil base" do
          expect(klass.call(flag: nil, flag_confirmation: true)).not_to be_ok
          expect(klass.call(flag_confirmation: false)).not_to be_ok
        end
      end

      context "with a :params base" do
        let(:klass) { build_axn { expects :payload, type: :params, confirmation: true } }

        it "demands a companion once the base is present" do
          expect(klass.call(payload: { a: 1 })).not_to be_ok
          expect(klass.call(payload: { a: 1 }, payload_confirmation: { a: 1 })).to be_ok
        end
      end
    end

    describe "a base carrying its own gate" do
      let(:gated) do
        build_axn do
          expects :admin, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: true, if: :admin
        end
      end

      it "leaves the companion unenforced while the base's own gate is closed" do
        expect(gated.call(admin: false, password: "s3cret")).to be_ok
        expect(gated.call(admin: false, password: "s3cret", password_confirmation: "nope")).to be_ok
      end

      it "enforces the companion once that gate opens" do
        expect(gated.call(admin: true, password: "s3cret")).not_to be_ok
        expect(gated.call(admin: true, password: "s3cret", password_confirmation: "nope")).not_to be_ok
        expect(gated.call(admin: true, password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      it "composes an unless: gate the same way" do
        klass = build_axn do
          expects :skip, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: true, unless: :skip
        end

        expect(klass.call(skip: true, password: "s3cret")).to be_ok
        expect(klass.call(skip: false, password: "s3cret")).not_to be_ok
        expect(klass.call(skip: false, password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      it "ANDs a base gate the author wrote as a list, rather than nesting it" do
        klass = build_axn do
          expects :a, type: [TrueClass, FalseClass], optional: true
          expects :b, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: true, if: %i[a b]
        end
        companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

        expect(companion.validations[:if]).to eq(%i[a b password])
        expect(klass.call(a: true, b: false, password: "s3cret")).to be_ok
        expect(klass.call(a: true, b: true, password: "s3cret")).not_to be_ok
      end
    end

    describe "the emitted schema" do
      it "states the requirement exactly for an ungated base" do
        schema = build_axn { expects :password, type: String, confirmation: true }.input_schema

        expect(schema[:required]).to eq(["password"])
        expect(schema[:allOf]).to eq(
          [{
            if: { required: ["password"], properties: { password: { not: { enum: [false, nil] } } } },
            then: { required: ["password_confirmation"] },
          }],
        )
      end

      # Neither a composed gate nor a presence-asking callable is a single Symbol, so
      # `conditional_requiredness_clause` falls back — and the fallback must be the STRICTER direction (an
      # unconditional requirement the runtime may waive), never a dropped one the runtime would enforce.
      it "falls back to an unconditional requirement for a gated base" do
        schema = build_axn do
          expects :admin, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: true, if: :admin
        end.input_schema

        expect(schema[:required]).to include("password_confirmation")
        expect(schema[:allOf].flat_map { |clause| clause.dig(:then, :required).to_a })
          .not_to include("password_confirmation")
      end

      it "falls back the same way for a base that admits a blank value" do
        schema = build_axn { expects :password, type: String, optional: true, confirmation: true }.input_schema

        expect(schema[:required]).to include("password_confirmation")
        expect(schema[:allOf]).to be_nil
      end
    end

    it "holds its generated reader to the same collision bar as a declared one" do
      expect do
        build_axn do
          expects :other, as: :password_confirmation, type: String, optional: true
          expects :password, type: String, confirmation: true
        end
      end.to raise_error(ArgumentError, /Reader name collision: password_confirmation/)
    end

    it "still reports a genuinely duplicated explicit declaration" do
      expect do
        build_axn do
          expects :password, type: String, confirmation: true
          expects :password_confirmation, type: String, optional: true
          expects :password_confirmation, type: String, optional: true
        end
      end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /password_confirmation/)
    end

    it "works on a subfield" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, type: String, confirmation: true
      end
      expect(klass.call(payload: { password: "a", password_confirmation: "b" })).not_to be_ok
      expect(klass.call(payload: { password: "a", password_confirmation: "a" })).to be_ok
    end

    it "stands down on a subfield when the author declares the companion explicitly, in either order" do
      after = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, type: String, confirmation: true
        expects :password_confirmation, on: :payload, type: String, optional: true
      end
      before = build_axn do
        expects :payload, type: Hash
        expects :password_confirmation, on: :payload, type: String, optional: true
        expects :password, on: :payload, type: String, confirmation: true
      end

      [after, before].each do |klass|
        companions = klass.send(:subfield_configs).select { |c| c.field == :password_confirmation }
        expect(companions.size).to eq(1)
        # The author's declaration is the one that stands: `optional:` means an omitted companion passes.
        expect(klass.call(payload: { password: "a" })).to be_ok
        expect(klass.call(payload: { password: "a", password_confirmation: "b" })).not_to be_ok
      end
    end
  end

  describe "the companion on the sensitive and tool surfaces" do
    it "redacts the companion when the base field is sensitive" do
      klass = build_axn { expects :password, type: String, sensitive: true, confirmation: true }
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

      expect(companion.sensitive).to be(true)
    end

    # Mirrors spec/axn/core/dynamic_sensitive_spec.rb's assertion style: the field-name filter
    # (`sensitive_fields`) and both output paths it feeds (`inputs_for_logging`, and `inspect` via the
    # internal context facade) rather than the config flag alone, since the masking surface differs by
    # output path and a config-only assertion can pass while a real path still leaks.
    it "masks the companion's value on every redaction output path, not just its declared config" do
      klass = build_axn { expects :password, type: String, sensitive: true, confirmation: true }

      expect(klass.sensitive_fields).to include(:password, :password_confirmation)

      instance = klass.send(:new, password: "s3cret", password_confirmation: "s3cret")
      expect(instance.send(:inputs_for_logging)[:password_confirmation]).to eq("[FILTERED]")

      result = klass.call(password: "s3cret", password_confirmation: "s3cret")
      expect(result.__action__.internal_context.inspect).to include("password_confirmation: [FILTERED]")
    end

    # `reject_undeclared_inputs` is a per-call gate only the tool Invoker sets in production
    # (lib/axn/tools/invoker.rb), so exercising it means setting it the way
    # spec/axn/core/tool_invocation_gates_spec.rb does rather than calling the action plainly — a plain
    # call never reaches the gate at all and would pass whether or not the companion were exempt.
    it "accepts the companion under reject_undeclared_inputs, matching a tool call that sends exactly the declared pair" do
      klass = build_axn { expects :password, type: String, confirmation: true }

      result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true, user_facing_input_errors: true) do
        klass.call(password: "s3cret", password_confirmation: "s3cret")
      end

      expect(result).to be_ok
    end
  end

  describe "positions where it cannot be honored" do
    it "refuses confirmation: on exposes" do
      expect do
        build_axn { exposes :token, type: String, confirmation: true }
      end.to raise_error(ArgumentError, /does not support confirmation:/)
    end

    it "refuses confirmation: on a shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :password, type: String, confirmation: true
          end
        end
      end.to raise_error(ArgumentError, /shape member `password` does not support confirmation:/)
    end
  end
end
