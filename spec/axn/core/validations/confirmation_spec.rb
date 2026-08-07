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
            result = klass.call(password_confirmation: "nope")
            expect(result).not_to be_ok
            expect(result.exception.message).to match(/confirmation doesn't match/)

            result = klass.call(password: nil, password_confirmation: "nope")
            expect(result).not_to be_ok
            expect(result.exception.message).to match(/confirmation doesn't match/)
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
          result = klass.call(flag: nil, flag_confirmation: true)
          expect(result).not_to be_ok
          expect(result.exception.message).to match(/confirmation doesn't match/)

          result = klass.call(flag_confirmation: false)
          expect(result).not_to be_ok
          expect(result.exception.message).to match(/confirmation doesn't match/)
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

    # ActiveModel skips a validator outright for a value its `allow_blank:` excuses, so a `confirmation:`
    # entry carrying one is not asked about a blank base at all — and neither is the companion feeding it,
    # even where the base's own contract refuses that blank value on its own account.
    describe "a confirmation: entry that excuses a blank base" do
      let(:klass) { build_axn { expects :password, type: String, confirmation: { allow_blank: true } } }

      it "asks nothing of the companion for a blank base the comparison skips" do
        result = klass.call(password: "")
        expect(result).not_to be_ok
        expect(result.exception.message).to eq("Password can't be blank")
      end

      it "still requires and compares the companion for a base the comparison acts on" do
        expect(klass.call(password: "s3cret")).not_to be_ok
        expect(klass.call(password: "s3cret", password_confirmation: "nope")).not_to be_ok
        expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      # The cost of asking presence rather than truthiness: the requirement is a callable, which
      # `conditional_requiredness_clause` cannot state as an `if`/`then` pair, so the schema demands the
      # companion unconditionally — stricter than the runtime, the direction this layer already accepts.
      it "advertises the companion as unconditionally required" do
        expect(klass.input_schema[:required]).to include("password_confirmation")
        expect(klass.input_schema[:allOf]).to be_nil
      end

      # An `allow_nil:` excuses only a nil base, which the requirement's own rule already closes on in
      # either spelling — so it costs the exact clause nothing.
      it "keeps the exact requirement for an entry that excuses only a nil base" do
        nil_tolerant = build_axn { expects :password, type: String, confirmation: { allow_nil: true } }
        companion = nil_tolerant.internal_field_configs.find { |c| c.field == :password_confirmation }

        expect(companion.validations[:if]).to eq(:password)
        expect(nil_tolerant.input_schema[:allOf].flat_map { |clause| clause.dig(:then, :required).to_a })
          .to include("password_confirmation")
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

      # A gate on the `confirmation:` ENTRY gates the comparison itself, so the companion it requires has to
      # answer to it too — otherwise a disabled confirmation still rejects an omitted companion nothing
      # would have compared.
      it "composes a gate carried by the confirmation: entry itself" do
        klass = build_axn do
          expects :want, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: { if: :want }
        end
        companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

        expect(companion.validations[:if]).to eq(%i[want password])
        expect(klass.call(want: false, password: "s3cret")).to be_ok
        expect(klass.call(want: false, password: "s3cret", password_confirmation: "nope")).to be_ok
        expect(klass.call(want: true, password: "s3cret")).not_to be_ok
        expect(klass.call(want: true, password: "s3cret", password_confirmation: "nope")).not_to be_ok
        expect(klass.call(want: true, password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      it "composes an unless: on the confirmation: entry the same way" do
        klass = build_axn do
          expects :skip, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: { unless: :skip }
        end
        companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

        expect(companion.validations[:unless]).to eq(:skip)
        expect(klass.call(skip: true, password: "s3cret")).to be_ok
        expect(klass.call(skip: false, password: "s3cret")).not_to be_ok
        expect(klass.call(skip: false, password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      # ActiveModel merges the two tiers per key, so an entry-level value REPLACES the declaration's for
      # that key — including a blank one, which un-gates the comparison. The companion follows: it is
      # required wherever the comparison runs, and here that is everywhere.
      it "follows an entry-level gate that overrides the declaration's" do
        klass = build_axn do
          expects :admin, type: [TrueClass, FalseClass], optional: true
          expects :password, type: String, confirmation: { if: nil }, if: :admin
        end
        companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

        expect(companion.validations[:if]).to eq(:password)
        expect(klass.call(password: "s3cret")).not_to be_ok
        expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
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

    # An `on:` on the ENTRY names an ActiveModel validation CONTEXT, and axn validates with no context, so
    # such a check runs on no call at all. That is refused at declaration for every validator, `confirmation:`
    # included, which is why the companion builder never has to reason about a comparison that cannot fire.
    # Pinned here because the two rules meet: without the refusal, the entry would declare a companion whose
    # presence is enforced while the comparison it serves never runs.
    describe "a confirmation: entry naming a validation context" do
      it "is refused at declaration rather than declaring a companion for a check that never runs" do
        expect do
          build_axn { expects :password, type: String, optional: true, confirmation: { on: :create } }
        end.to raise_error(ArgumentError, /names an ActiveModel validation context/)
      end

      it "is refused on the subfield route the same way" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :password, on: :payload, type: String, optional: true, confirmation: { on: :create }
          end
        end.to raise_error(ArgumentError, /names an ActiveModel validation context/)
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

      # The companion's own `presence: true` carries no tolerance of its own (it is not relaxed to mirror
      # the base's `optional:`/`allow_empty:`), so the emitted size floor (minLength/minItems) stands on
      # the companion property even where the base admits a blank value and the runtime gate never runs
      # the presence check for a blank-matching pair (`password: "", password_confirmation: ""` calls
      # cleanly — the gate closes because the base has nothing to confirm). This is the same direction,
      # via the same mechanism, as an ordinary gated field's own floor (the `if:`-gated base above emits
      # `minLength: 1` on `password` despite `if: :admin`): the reflection layer counts a gated check as
      # though it always ran, which can only make the schema STRICTER than the runtime it's read from,
      # never looser — so a schema-following caller is refused the blank-matching pair the runtime would
      # accept, accepted here as the documented cost of staying on the strict side of that line.
      it "keeps the companion's own size floor though a blank-admitting base never enforces it at runtime" do
        password_schema = build_axn { expects :password, type: String, optional: true, confirmation: true }.input_schema
        expect(password_schema[:properties][:password_confirmation]).to include(minLength: 1)

        tags_schema = build_axn { expects :tags, type: Array, allow_empty: true, confirmation: true }.input_schema
        expect(tags_schema[:properties][:tags_confirmation]).to include(minItems: 1)
      end
    end

    # The companion's reader is INFERRED, so a clash with it is never the explicit-vs-explicit conflict
    # the collision guards raise on: the name goes to whoever declared it (or wrote the method), and the
    # companion yields it — in either declaration order. The companion's own CONFIG is untouched by that:
    # a reader-less companion is enforced against the wire value, so the pair is still compared and still
    # required.
    describe "its generated reader, when something else already holds the name" do
      it "yields the name to a reader an unrelated as: claimed first" do
        klass = build_axn do
          expects :other, as: :password_confirmation, type: String, optional: true
          expects :password, type: String, confirmation: true
        end

        expect(klass.call(other: "unrelated", password: "s3cret", password_confirmation: "nope")).not_to be_ok
        expect(klass.call(other: "unrelated", password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      it "yields the name to an unrelated as: declared after it" do
        klass = build_axn do
          expects :password, type: String, confirmation: true
          expects :other, as: :password_confirmation, type: String, optional: true
        end

        klass.class_eval do
          exposes :seen
          def call = expose(seen: password_confirmation)
        end

        expect(klass.call(other: "unrelated", password: "s3cret", password_confirmation: "s3cret").seen).to eq("unrelated")
        expect(klass.call(other: "unrelated", password: "s3cret", password_confirmation: "nope")).not_to be_ok
      end

      it "yields the name to a method the author wrote" do
        klass = build_axn do
          def pw_confirmation = "USER METHOD"
          expects :password, as: :pw, type: String, confirmation: true
          exposes :seen
          def call = expose(seen: pw_confirmation)
        end

        expect(klass.call(password: "s3cret", password_confirmation: "s3cret").seen).to eq("USER METHOD")
        expect(klass.call(password: "s3cret", password_confirmation: "nope")).not_to be_ok
      end

      # A subfield's reader normally IS its value, so validation reads it — but a deferred companion's
      # name is the author's method, not the config's reader, and validating that method's answer would
      # let it stand in for the input the pair is supposed to require.
      it "validates a subfield companion against the wire value, not the method it deferred to" do
        klass = build_axn do
          def pw_confirmation = "USER METHOD"
          expects :payload, type: Hash
          expects :password, on: :payload, as: :pw, type: String, confirmation: true
        end

        expect(klass.call(payload: { password: "s3cret", password_confirmation: "s3cret" })).to be_ok
        expect(klass.call(payload: { password: "s3cret", password_confirmation: "nope" })).not_to be_ok
        expect(klass.call(payload: { password: "s3cret" })).not_to be_ok
      end

      # A deferred companion is still eligible as a subfield's `on:` PARENT. Resolving that parent by
      # dispatching the name reads the author's method, so the child would be validated — and read — against
      # a value the companion's own contract never saw, accepting an invalid wire value.
      it "resolves a subfield whose on: parent is a deferred companion against the wire value" do
        klass = build_axn do
          def pw_confirmation = { code: 1 }
          expects :password, as: :pw, type: Hash, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        expect(klass.call(password: { code: "bad" }, password_confirmation: { code: "bad" })).not_to be_ok
        expect(klass.call(password: { code: 7 }, password_confirmation: { code: 7 }).seen).to eq(7)
      end

      it "resolves through a deferred subfield companion the same way" do
        klass = build_axn do
          def pw_confirmation = { code: 1 }
          expects :payload, type: Hash
          expects :password, on: :payload, as: :pw, type: Hash, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        expect(klass.call(payload: { password: { code: "bad" }, password_confirmation: { code: "bad" } })).not_to be_ok
        expect(klass.call(payload: { password: { code: 7 }, password_confirmation: { code: 7 } }).seen).to eq(7)
      end

      # `on:` names a READER, and here the name belongs to the DECLARATION the companion yielded it to — so
      # the child reads that declaration's value. Anchoring on the yielding companion instead would validate
      # and read the child against a field the caller reached by a different name entirely, and which of
      # the two answered would come down to declaration order.
      it "anchors a subfield on the declaration holding the name, not the companion that yielded it" do
        klass = build_axn do
          expects :other, type: Hash, as: :pw_confirmation
          expects :password, as: :pw, type: Hash, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        expect(klass.call(other: { code: 1 }, password: { code: "x" }, password_confirmation: { code: "x" }).seen).to eq(1)
        expect(klass.call(other: { code: "bad" }, password: { code: 1 }, password_confirmation: { code: 1 })).not_to be_ok
      end

      it "anchors there in the other declaration order too" do
        klass = build_axn do
          expects :password, as: :pw, type: Hash, confirmation: true
          expects :other, type: Hash, as: :pw_confirmation
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        expect(klass.call(other: { code: 1 }, password: { code: "x" }, password_confirmation: { code: "x" }).seen).to eq(1)
        expect(klass.call(other: { code: "bad" }, password: { code: 1 }, password_confirmation: { code: 1 })).not_to be_ok
      end

      it "anchors on the declaration on the subfield route the same way" do
        klass = build_axn do
          expects :payload, type: Hash
          expects :other, on: :payload, type: Hash, as: :pw_confirmation
          expects :password, on: :payload, as: :pw, type: Hash, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        expect(klass.call(payload: { other: { code: 1 }, password: { code: "x" }, password_confirmation: { code: "x" } }).seen).to eq(1)
        expect(klass.call(payload: { other: { code: "bad" }, password: { code: 1 }, password_confirmation: { code: 1 } })).not_to be_ok
      end

      # Two spellings of one route (`on: :bar` and `on: "foo.bar"`) reach the same wire leaf, so the
      # companion and the author's own same-named declaration land on ONE node. The declaration still owns
      # the reader, so the child reads through its transform rather than the companion's.
      it "anchors on the declaration when both share a node through two spellings of one route" do
        klass = build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :password, on: :bar, type: Hash, confirmation: true, preprocess: ->(h) { h.merge(src: "companion") }
          expects :password_confirmation, on: "foo.bar", type: Hash, preprocess: ->(h) { h.merge(src: "declaration") }
          expects :src, on: :password_confirmation, type: String
          exposes :seen
          def call = expose(seen: src)
        end

        expect(klass.call(foo: { bar: { password: { a: 1 }, password_confirmation: { a: 1 } } }).seen).to eq("declaration")
      end

      # A companion that yields the name still reflects its OWN contract. The subfields declared `on:` that
      # name belong to the declaration holding it (above), so the companion has none — emitting the
      # name-holder's nesting under it would advertise an object property for a String no caller could
      # supply a matching pair for.
      it "emits its own contract in the schema, not that of the declaration holding the name" do
        klass = build_axn do
          expects :other, type: Hash, as: :pw_confirmation
          expects :password, as: :pw, type: String, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
        end

        schema = klass.input_schema
        expect(schema[:properties][:password_confirmation]).to eq({ type: "string", minLength: 1 })
        expect(schema[:properties][:other]).to eq({ type: "object", minProperties: 1,
                                                    properties: { code: { type: "integer" } }, required: ["code"] })
        # Having no subfields of its own, the companion's requirement states its gate exactly rather than
        # falling back to an unconditional one.
        expect(schema[:required]).to contain_exactly("other", "password")
        expect(schema[:allOf]).to eq([{ if: { required: ["password"], properties: { password: { not: { enum: [false, nil] } } } },
                                        then: { required: ["password_confirmation"] } }])
        # And the schema a client generates from it is satisfiable: that pair validates.
        expect(klass.call(other: { code: 1 }, password: "s3cret", password_confirmation: "s3cret")).to be_ok
      end

      it "emits its own contract in the other declaration order too" do
        klass = build_axn do
          expects :password, as: :pw, type: String, confirmation: true
          expects :other, type: Hash, as: :pw_confirmation
          expects :code, on: :pw_confirmation, type: Integer
        end

        schema = klass.input_schema
        expect(schema[:properties][:password_confirmation]).to eq({ type: "string", minLength: 1 })
        expect(schema[:properties][:other][:properties]).to eq({ code: { type: "integer" } })
      end

      # Three questions, one rule: a reader NAME belongs to the config that answers to it. Each is
      # asked in both declaration orders, so a fix that only re-orients one side still fails the pair.
      %i[companion_first declaration_first].each do |order|
        # A Symbol gate names a READER, so the clause a gated sibling emits must key on the wire key of
        # whoever answers to it. Keying on the companion's instead conditions the sibling on a value the
        # runtime gate never reads.
        it "conditions a Symbol gate on the declaration holding the name (#{order})" do
          klass = build_axn do
            if order == :companion_first
              expects :password, as: :pw, type: String, confirmation: true
              expects :other, as: :pw_confirmation, type: String, optional: true
            else
              expects :other, as: :pw_confirmation, type: String, optional: true
              expects :password, as: :pw, type: String, confirmation: true
            end
            expects :thing, type: String, if: :pw_confirmation
          end

          expect(klass.input_schema[:allOf]).to include(
            { if: { required: ["other"], properties: { other: { not: { enum: [false, nil] } } } },
              then: { required: ["thing"] } },
          )
          # The runtime the clause mirrors: the gate reads `other`, so a supplied pair alone leaves it shut.
          expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
          expect(klass.call(other: "x", password: "s3cret", password_confirmation: "s3cret")).not_to be_ok
        end

        # One reader name is one namespace across both tiers, so a SUBFIELD declaration can take the name
        # a top-level companion generated — and `on:` that name then belongs to the subfield.
        it "anchors on a subfield declaration that holds a top-level companion's name (#{order})" do
          klass = build_axn do
            if order == :companion_first
              expects :password, type: Hash, confirmation: true
              expects :payload, type: Hash
              expects :password_confirmation, on: :payload, type: Hash
            else
              expects :payload, type: Hash
              expects :password_confirmation, on: :payload, type: Hash
              expects :password, type: Hash, confirmation: true
            end
            expects :code, on: :password_confirmation, type: Integer
            exposes :seen
            def call = expose(seen: code)
          end

          nested = klass.input_schema[:properties][:payload][:properties][:password_confirmation]
          expect(nested[:properties]).to eq({ code: { type: "integer" } })
          expect(klass.input_schema[:properties][:password_confirmation][:properties]).to be_nil

          result = klass.call(password: { a: 1 }, password_confirmation: { a: 1 }, payload: { password_confirmation: { code: 7 } })
          expect(result.seen).to eq(7)
        end

        # The collision bar asks whether a name is already claimed under a DIFFERENT wire key, so the wire
        # key it compares has to be the owner's. Crediting the companion with a name it only spells turns a
        # plain redeclaration into a reader-name collision on one side of the pair and not the other.
        it "reports a redeclared name-holder as the duplicate field it is (#{order})" do
          expect do
            build_axn do
              if order == :companion_first
                expects :password, as: :pw, type: String, confirmation: true
                expects :other, as: :pw_confirmation, type: String
              else
                expects :other, as: :pw_confirmation, type: String
                expects :password, as: :pw, type: String, confirmation: true
              end
              expects :other, as: :pw_confirmation, type: Integer
            end
          end.to raise_error(Axn::ContractViolation::DuplicateFieldError, /other/)
        end
      end

      # Two companions can land on one name when a top-level declaration takes a subfield's wire key (the
      # same-wire-key exemption) and both carry `confirmation:`. Both readers are inferred, so they target
      # the same module and the FIRST generated keeps the name — the subfield's, since the pair only
      # survives with the subfield declared first. `on:` that name follows it, so the descendant is
      # reflected and validated on the subfield route.
      it "anchors on the subfield companion when two companions share a name" do
        klass = build_axn do
          expects :payload, type: Hash
          expects :pw, on: :payload, type: Hash, confirmation: true
          expects :pw, type: Hash, confirmation: true
          expects :code, on: :pw_confirmation, type: Integer
          exposes :seen
          def call = expose(seen: code)
        end

        schema = klass.input_schema
        expect(schema[:properties][:payload][:properties][:pw_confirmation][:properties]).to eq({ code: { type: "integer" } })
        expect(schema[:properties][:pw_confirmation][:properties]).to be_nil

        pair = { pw: { code: 7 }, pw_confirmation: { code: 7 } }
        expect(klass.call(**pair, payload: { pw: { code: 1 }, pw_confirmation: { code: 7 } }).seen).to eq(7)
        expect(klass.call(pw: { code: "bad" }, pw_confirmation: { code: "bad" },
                          payload: { pw: { code: 1 }, pw_confirmation: { code: "bad" } })).not_to be_ok
      end

      # Which config owns a name is settled over the WHOLE contract, so a subfield that takes a companion's
      # name is the anchor for `on:` that name even where it is declared after the config anchoring on it.
      # Resolving each anchor as the declarations arrive reads the companion in one order and the subfield
      # in the other, putting one contract on two different wire paths — and the emitted schema and the
      # runtime read move together, so neither side reveals the other is wrong.
      %i[anchor_first claimant_first].each do |order|
        it "anchors on the subfield holding the name wherever that subfield is declared (#{order})" do
          klass = build_axn do
            expects :password, as: :pw, type: Hash, confirmation: true
            expects :payload, type: Hash
            if order == :anchor_first
              expects :code, on: :pw_confirmation, type: Integer
              expects :nested, on: :payload, as: :pw_confirmation, type: Hash
            else
              expects :nested, on: :payload, as: :pw_confirmation, type: Hash
              expects :code, on: :pw_confirmation, type: Integer
            end
            exposes :seen
            def call = expose(seen: code)
          end

          schema = klass.input_schema
          expect(schema[:properties][:payload][:properties][:nested][:properties]).to eq({ code: { type: "integer" } })
          expect(schema[:properties][:password_confirmation][:properties]).to be_nil

          # And the runtime reads the value from the path the schema advertises.
          result = klass.call(password: { code: 1 }, password_confirmation: { code: 1 }, payload: { nested: { code: 7 } })
          expect(result.seen).to eq(7)
        end
      end

      # A yielded name is the only thing that lets an `on:` chain loop at all: an `on:` root must be declared
      # to pass the missing-reader check, so without a name changing hands every chain ends at a top-level
      # field. A loop names no value to read from, in either direction and at either end.
      %i[forwards backwards].each do |order|
        it "rejects an on: chain that loops back through a name a companion yielded (#{order})" do
          expect do
            build_axn do
              expects :alpha, as: :a, type: Hash, confirmation: true
              expects :beta, as: :b, type: Hash, confirmation: true
              if order == :forwards
                expects :x, on: :a_confirmation, as: :b_confirmation, type: Hash
                expects :y, on: :b_confirmation, as: :a_confirmation, type: Hash
              else
                expects :y, on: :b_confirmation, as: :a_confirmation, type: Hash
                expects :x, on: :a_confirmation, as: :b_confirmation, type: Hash
              end
            end
          end.to raise_error(ArgumentError, /circular on: chain.*:x.*:y|circular on: chain.*:y.*:x/m)
        end
      end

      it "rejects a subfield declared on the very name it takes over" do
        expect do
          build_axn do
            expects :alpha, as: :a, type: Hash, confirmation: true
            expects :x, on: :a_confirmation, as: :a_confirmation, type: Hash
          end
        end.to raise_error(ArgumentError, /circular on: chain/)
      end
    end

    describe "when an explicit declaration supersedes it" do
      it "withdraws the reader it generated rather than leaving it resolving through the dropped config" do
        klass = build_axn do
          expects :password, as: :pw, type: String, confirmation: true
          expects :password_confirmation, as: :confirmed, type: String, preprocess: ->(s) { s&.upcase }
        end

        expect(klass.instance_methods).to include(:confirmed)
        expect(klass.instance_methods).not_to include(:pw_confirmation)
      end

      it "withdraws a subfield companion's reader the same way" do
        klass = build_axn do
          expects :payload, type: Hash
          expects :password, on: :payload, as: :pw, type: String, confirmation: true
          expects :password_confirmation, on: :payload, as: :confirmed, type: String, preprocess: ->(s) { s&.upcase }
        end

        expect(klass.instance_methods).to include(:confirmed)
        expect(klass.instance_methods).not_to include(:pw_confirmation)
      end

      it "leaves a same-named method the author wrote standing" do
        klass = build_axn do
          def pw_confirmation = "USER METHOD"
          expects :password, as: :pw, type: String, confirmation: true
          expects :password_confirmation, as: :confirmed, type: String
          exposes :seen
          def call = expose(seen: pw_confirmation)
        end

        expect(klass.call(password: "s3cret", password_confirmation: "s3cret").seen).to eq("USER METHOD")
      end

      # The `?` predicate is an ALIAS — an independent copy of the reader's body — so withdrawing the
      # primary reader alone leaves the predicate resolving through the config the explicit declaration
      # dropped, answering under a name that declaration now owns.
      it "withdraws the boolean predicate riding on that reader too" do
        klass = build_axn do
          expects :flag, as: :fl, type: :boolean, confirmation: true
          expects :flag_confirmation, as: :confirmed, type: :boolean
        end

        expect(klass.instance_methods).to include(:confirmed, :confirmed?)
        expect(klass.instance_methods).not_to include(:fl_confirmation, :fl_confirmation?)
      end

      it "withdraws a subfield companion's predicate the same way" do
        klass = build_axn do
          expects :payload, type: Hash
          expects :flag, on: :payload, as: :fl, type: :boolean, confirmation: true
          expects :flag_confirmation, on: :payload, as: :confirmed, type: :boolean
        end

        expect(klass.instance_methods).to include(:confirmed, :confirmed?)
        expect(klass.instance_methods).not_to include(:fl_confirmation, :fl_confirmation?)
      end

      it "leaves a same-named predicate the author wrote standing" do
        klass = build_axn do
          def fl_confirmation? = "USER PREDICATE"
          expects :flag, as: :fl, type: :boolean, confirmation: true
          expects :flag_confirmation, as: :confirmed, type: :boolean
          exposes :seen
          def call = expose(seen: fl_confirmation?)
        end

        expect(klass.instance_methods).not_to include(:fl_confirmation)
        expect(klass.call(flag: true, flag_confirmation: true).seen).to eq("USER PREDICATE")
      end

      it "withdraws an inherited companion's reader on the subclass alone" do
        parent = build_axn { expects :password, as: :pw, type: String, confirmation: true }
        child = Class.new(parent) { expects :password_confirmation, as: :confirmed, type: String }

        expect(child.instance_methods).not_to include(:pw_confirmation)
        expect(parent.instance_methods).to include(:pw_confirmation)
      end
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

    describe "the emitted input schema" do
      it "advertises the companion, conditionally required on the base field" do
        klass = build_axn { expects :password, type: String, confirmation: true }
        schema = klass.input_schema

        expect(schema[:properties]).to have_key(:password_confirmation)
        expect(schema[:required]).to contain_exactly("password")
        expect(schema[:allOf]).to eq(
          [{ if: { required: ["password"], properties: { password: { not: { enum: [false, nil] } } } },
             then: { required: ["password_confirmation"] } }],
        )
      end

      it "resolves requiredness independently of declaration order" do
        a = build_axn do
          expects :password, type: String, confirmation: true
          expects :other, type: String, optional: true
        end
        b = build_axn do
          expects :other, type: String, optional: true
          expects :password, type: String, confirmation: true
        end
        expect(a.input_schema[:allOf]).to eq(b.input_schema[:allOf])
      end
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
