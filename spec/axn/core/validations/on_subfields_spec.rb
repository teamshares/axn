# frozen_string_literal: true

RSpec.describe Axn do
  describe "_expects_subfields" do
    shared_examples "raises when improperly configured" do |on:|
      it "raises" do
        expect { action }.to raise_error(
          ArgumentError,
          "expects called with `on: #{on}`, but no such reader exists " \
          "(are you sure you've declared a field — or alias — named :#{on}?)",
        )
      end
    end

    context "when missing expects declaration" do
      let(:action) { build_axn { expects :bar, on: :baz } }
      it_behaves_like "raises when improperly configured", on: :baz
    end

    context "when missing nested expects declaration" do
      let(:action) do
        build_axn do
          expects :baz
          expects :bar, on: :baz
          expects :quux, on: :qux
        end
      end
      it_behaves_like "raises when improperly configured", on: :qux
    end

    let(:readers) { true }
    let(:action) do
      build_axn do
        expects :foo
        expects :bar, :baz, on: :foo
        exposes :output

        def call
          expose output: qux
        end
      end.tap do |action|
        action.expects :qux, on: :bar, readers:
      end
    end

    it "validates" do
      expect(action.call(foo: { bar: { qux: 3 }, baz: 2 })).to be_ok
      expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
      expect(action.call(foo: 1)).not_to be_ok
    end

    context "with optional: true on subfields" do
      let(:action) do
        build_axn do
          expects :foo, optional: true
          expects :bar, :baz, on: :foo, optional: true, type: String
          exposes :output, optional: true

          def call
            expose output: "success"
          end
        end
      end

      context "when subfield is missing" do
        subject { action.call(foo: {}) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is nil" do
        subject { action.call(foo: { bar: nil, baz: nil }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is blank" do
        subject { action.call(foo: { bar: "", baz: "   " }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has valid value" do
        subject { action.call(foo: { bar: "hello", baz: "world" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end
    end

    context "with optional: true and type validation on subfields" do
      let(:action) do
        build_axn do
          expects :foo, optional: true
          expects :name, on: :foo, type: String, optional: true
          exposes :output, optional: true

          def call
            expose output: "success"
          end
        end
      end

      context "when subfield is missing" do
        subject { action.call(foo: {}) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is nil" do
        subject { action.call(foo: { name: nil }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield is empty string" do
        subject { action.call(foo: { name: "" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has valid string value" do
        subject { action.call(foo: { name: "John" }) }

        it "passes validation" do
          is_expected.to be_ok
        end
      end

      context "when subfield has invalid type" do
        subject { action.call(foo: { name: 123 }) }

        it "fails validation" do
          is_expected.not_to be_ok
          expect(subject.exception.message).to include("is not a String")
        end
      end
    end

    # A nil/absent parent must be treated as "subfields absent" — each subfield's own optional/required
    # rules apply — rather than blowing up when the resolver tries to extract from nil (PRO-2857).
    context "when the parent is nil or absent" do
      context "with all-optional subfields" do
        let(:action) do
          build_axn do
            expects :payload, optional: true
            expects :name, on: :payload, optional: true, type: String
            def call = nil
          end
        end

        it "passes when the parent is omitted" do
          expect(action.call).to be_ok
        end

        it "passes when the parent is explicitly nil" do
          expect(action.call(payload: nil)).to be_ok
        end
      end

      context "with a nil-tolerant typed parent (type: Hash, allow_nil: true)" do
        let(:action) do
          build_axn do
            expects :payload, type: Hash, allow_nil: true
            expects :name, on: :payload, optional: true, type: String
            def call = nil
          end
        end

        it "passes when the parent is explicitly nil" do
          expect(action.call(payload: nil)).to be_ok
        end
      end

      context "with a required subfield" do
        # A nil-tolerant parent (optional:) can never satisfy a required subfield — a nil/omitted
        # parent yields the subfield absent (PRO-2857), so this is now rejected at declaration rather
        # than reconciled at runtime (family 1, PRO-2877).
        it "raises at declaration instead of reconciling at runtime" do
          expect do
            build_axn do
              expects :payload, optional: true
              expects :name, on: :payload, type: String
              def call = nil
            end
          end.to raise_error(ArgumentError, %r{:payload is declared nil-tolerant \(allow_nil:/optional:\) but :name .* is required})
        end
      end

      context "with a preprocessed subfield" do
        let(:action) do
          build_axn do
            expects :payload, optional: true
            expects :name, on: :payload, optional: true, type: String, preprocess: ->(v) { v.to_s.strip }
            exposes :name_val, allow_nil: true
            def call = expose(name_val: name)
          end
        end

        it "does not raise when the parent is nil" do
          expect(action.call(payload: nil)).to be_ok
        end

        it "leaves the subfield absent when the parent is nil (the preprocess does not synthesize a parent)" do
          # A nil/absent parent means the subfield is absent — the preprocess result has nowhere to land and
          # is dropped, rather than materializing the parent. (A present-but-empty `{}` parent differs: the
          # subfield is present there, so the preprocess runs and its result — "" — is stored.)
          expect(action.call(payload: nil).name_val).to be_nil
          expect(action.call.name_val).to be_nil
          expect(action.call(payload: {}).name_val).to eq("")
        end
      end

      context "with a REQUIRED parent and a preprocessed subfield" do
        let(:action) do
          build_axn do
            expects :payload
            expects :name, on: :payload, optional: true, type: String, preprocess: ->(v) { v.to_s.strip }
            def call = nil
          end
        end

        it "still fails parent presence when omitted (preprocess must not synthesize a required parent)" do
          # The preprocess returns "" (non-nil) for an absent subfield; materializing `{name: ""}` would
          # make the non-empty hash satisfy the parent's presence and let a required parent through on no
          # input. It must not — unlike a subfield default, a preprocess doesn't synthesize the parent.
          result = action.call
          expect(result).not_to be_ok
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("can't be blank")
        end

        it "runs the subfield preprocess normally when the required parent IS provided" do
          expect(action.call(payload: {})).to be_ok
        end
      end

      context "with a type-required parent whose nil-rejection is NOT from presence" do
        # `type: :params` (and `type: Hash, presence: false`) reject nil via the TYPE validator, with no
        # `presence` key — so materializing `{name: …}` would satisfy the type and let an unsupplied
        # required parent through. Nil-tolerance must be judged from the full validator set, not presence.
        it "fails a required type: :params parent when omitted (not synthesized by a preprocessed subfield)" do
          action = build_axn do
            expects :payload, type: :params
            expects :name, on: :payload, optional: true, type: String, preprocess: ->(v) { v.to_s.strip }
            def call = nil
          end
          expect(action.call).not_to be_ok
        end

        it "fails a required type: Hash, presence: false parent when omitted" do
          action = build_axn do
            expects :payload, type: Hash, presence: false
            expects :name, on: :payload, optional: true, type: String, preprocess: ->(v) { v.to_s.strip }
            def call = nil
          end
          expect(action.call).not_to be_ok
        end
      end

      context "with a non-object (type: Array) parent — must not be materialized into a Hash" do
        it "treats a nil Array parent as absent for a preprocessed subfield (no spurious type error)" do
          action = build_axn do
            expects :items, type: Array, optional: true
            expects :count, on: :items, optional: true, type: Integer, preprocess: ->(v) { v }
            def call = nil
          end
          expect(action.call(items: nil)).to be_ok
        end

        it "treats a nil Array parent as absent for a defaulted subfield (no spurious type error)" do
          action = build_axn do
            expects :items, type: Array, optional: true
            expects :count, on: :items, optional: true, type: Integer, default: 5
            def call = nil
          end
          expect(action.call(items: nil)).to be_ok
        end

        it "does not evaluate a Proc default when the nil parent isn't materialized (no side effects)" do
          ran = []
          action = build_axn do
            expects :items, type: Array, optional: true
            expects :count, on: :items, optional: true, type: Integer, default: -> { ran.push(5).last }
            def call = nil
          end
          expect(action.call(items: nil)).to be_ok
          expect(ran).to be_empty
        end

        it "does not raise on a dotted subfield default when the nil parent isn't materialized" do
          action = build_axn do
            expects :items, type: Array, optional: true
            expects "a.b", on: :items, optional: true, type: String, default: "x"
            def call = nil
          end
          result = action.call(items: nil)
          expect(result).to be_ok
          expect(result.exception).to be_nil
        end
      end

      context "with a defaulted parent and a preprocessed subfield" do
        let(:action) do
          build_axn do
            expects :payload, type: Hash, default: { name: "Ada", role: "eng" }
            expects :name, on: :payload, type: String, preprocess: ->(v) { v.to_s.upcase }
            exposes :payload_val, allow_nil: true
            def call = expose(payload_val: payload)
          end
        end

        it "applies the parent's default when omitted (preprocessing must not preempt it)" do
          # Preprocessing runs before defaults; materializing a synthetic {} here would make apply_defaults!
          # skip the now-non-nil key and drop the declared default. The default must still win.
          expect(action.call.payload_val).to eq({ name: "Ada", role: "eng" })
        end

        it "applies the parent's default when the parent is explicitly nil" do
          expect(action.call(payload: nil).payload_val).to eq({ name: "Ada", role: "eng" })
        end
      end

      context "with a nil-tolerant parent carrying both a shape block and an optional on: subfield" do
        let(:action) do
          build_axn do
            expects :payload, type: Hash, allow_nil: true do
              field :status, type: String
            end
            expects :note, on: :payload, optional: true, type: String
            def call = nil
          end
        end

        it "accepts a nil parent (shape validation is skipped, the optional subfield is absent)" do
          expect(action.call(payload: nil)).to be_ok
        end

        it "still enforces the required shape member when a non-nil parent is provided" do
          expect(action.call(payload: { note: "hi" })).not_to be_ok
        end
      end

      context "when a defaulted on: subfield synthesizes the parent into a required shape member" do
        let(:action) do
          build_axn do
            expects :payload, type: Hash, allow_nil: true do
              field :status, type: String
            end
            expects :note, on: :payload, optional: true, type: String, default: "x"
            def call = nil
          end
        end

        it "rejects a nil/absent parent (the default synthesizes it, so the required member is enforced)" do
          # Matches the schema, which reflects this parent as required + non-nullable.
          expect(action.call(payload: nil)).not_to be_ok
          expect(action.call).not_to be_ok
        end

        it "accepts a parent that supplies the required shape member" do
          expect(action.call(payload: { status: "ok" })).to be_ok
        end
      end
    end

    context "readers" do
      subject(:result) { action.call(foo: { bar: { qux: 3 }, baz: 2 }) }

      it "exposes by default" do
        expect(result).to be_ok
        expect(result.output).to eq(3)
      end

      context "can be disabled" do
        let(:readers) { false }

        it do
          expect(result).not_to be_ok
          expect(result.exception).to be_a(NameError)
        end
      end

      # `resolve_parent` reads a subfield parent via `public_send`, which a `readers: false` parent has
      # no method to answer — so naming one as an `on:` target crashed every call with NoMethodError while
      # reflection still advertised the nested path. Reject the unusable combination at declaration.
      context "when on: names a readers: false subfield (no reader to resolve the parent)" do
        it "raises at declaration naming the readers: false cause" do
          expect do
            build_axn do
              expects :payload
              expects :bar, on: :payload, readers: false
              expects :baz, on: :bar
            end
          end.to raise_error(
            ArgumentError,
            "expects called with `on: bar`, but :bar was declared with `readers: false` — " \
            "a subfield parent must have a reader for the runtime to resolve " \
            "(drop `readers: false` on :bar, or name a readable parent)",
          )
        end

        # `readers: false` skips reader generation and therefore the duplicate-sub-keys collision check,
        # so a subfield whose name shadows an inherited public method (e.g. :class, :hash) leaves
        # `method_defined?(name)` true even though axn generated no reader. The guard must consult the
        # set of readers axn actually generated, not `method_defined?` — otherwise `public_send(:class)`
        # reads the action class (not `payload[:class]`) at runtime while reflection advertises the path.
        it "raises when the readers: false parent's name shadows an inherited method (:class)" do
          expect do
            build_axn do
              expects :payload
              expects :class, on: :payload, readers: false
              expects :name, on: :class
            end
          end.to raise_error(
            ArgumentError,
            "expects called with `on: class`, but :class was declared with `readers: false` — " \
            "a subfield parent must have a reader for the runtime to resolve " \
            "(drop `readers: false` on :class, or name a readable parent)",
          )
        end

        it "raises for another inherited-method name (:hash), proving it is not :class-specific" do
          expect do
            build_axn do
              expects :payload
              expects :hash, on: :payload, readers: false
              expects :name, on: :hash
            end
          end.to raise_error(
            ArgumentError,
            "expects called with `on: hash`, but :hash was declared with `readers: false` — " \
            "a subfield parent must have a reader for the runtime to resolve " \
            "(drop `readers: false` on :hash, or name a readable parent)",
          )
        end

        # `readers: true` (the default) DOES generate the reader, so the collision check still fires
        # first for an inherited-method name — unchanged by the readerless-parent guard.
        it "still raises the duplicate-sub-keys error for a readers: true subfield named :class" do
          expect do
            build_axn do
              expects :payload
              expects :class, on: :payload
            end
          end.to raise_error(
            ArgumentError,
            "expects does not support duplicate sub-keys (i.e. `class` is already defined)",
          )
        end
      end

      # The generated-reader record must inherit copy-on-write so a subclass can anchor a subfield on a
      # parent whose reader was generated in the superclass.
      context "a normal chain (readers: true parent)" do
        it "declares without raising and resolves at runtime" do
          action = build_axn do
            expects :payload
            expects :bar, on: :payload
            expects :baz, on: :bar
          end

          expect(action.call(payload: { bar: { baz: 3 } })).to be_ok
        end

        it "lets a subclass anchor a subfield on a parent whose reader the superclass generated" do
          parent = build_axn do
            expects :payload
            expects :bar, on: :payload
          end

          child = Class.new(parent)
          expect { child.expects :baz, on: :bar }.not_to raise_error
          expect(child.call(payload: { bar: { baz: 3 } })).to be_ok
        end
      end
    end

    context "digging to nested fields" do
      let(:action) do
        build_axn do
          expects :foo
          expects "bar.baz", on: :foo
        end
      end

      it "validates" do
        expect(action.call(foo: { bar: { baz: 3 } })).to be_ok
        expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end

      context "with duplicate sub-keys" do
        let(:action) do
          build_axn do
            expects :foo
            expects :bar, on: :foo
          end.tap do |a|
            a.expects :foo, on: :bar, readers:
          end
        end

        context "when readers are enabled" do
          let(:readers) { true }

          it "raises if readers are enabled" do
            expect { action }.to raise_error(ArgumentError, "expects does not support duplicate sub-keys (i.e. `foo` is already defined)")
          end
        end

        context "when readers are disabled" do
          let(:readers) { false }

          it "does not create reader methods but still validates correctly" do
            expect { action }.not_to raise_error

            # Should not create a reader method for the nested field when readers: false
            expect(action).not_to respond_to(:foo)

            # But validation should still work correctly - with improved validation system,
            # validation works regardless of whether reader methods are created
            expect(action.call(foo: { bar: { foo: 3 } })).to be_ok
            expect(action.call(foo: { bar: { baz: 3 } })).not_to be_ok # Still fails validation as expected
          end
        end
      end
    end

    context "with a nested (dotted) on: path" do
      it "validates a field on a nested parent path" do
        action = build_axn do
          expects :address, type: Hash
          expects :postcode, on: "address.billing", type: String
        end

        expect(action.call(address: { billing: { postcode: "12345" } })).to be_ok
        expect(action.call(address: { billing: { postcode: 123 } })).not_to be_ok
      end

      it "defines a clean, dot-free reader named after the subfield" do
        action = build_axn do
          expects :address, type: Hash
          expects :postcode, on: "address.billing", type: String
          exposes :echoed

          def call
            expose :echoed, postcode
          end
        end

        expect(action.instance_methods).to include(:postcode)
        expect(action.call(address: { billing: { postcode: "12345" } }).echoed).to eq("12345")
      end

      it "supports nesting more than one level deep" do
        action = build_axn do
          expects :a, type: Hash
          expects :leaf, on: "a.b.c", type: String
        end

        expect(action.call(a: { b: { c: { leaf: "ok" } } })).to be_ok
        expect(action.call(a: { b: { c: { leaf: 9 } } })).not_to be_ok
      end

      it "supports optional: when the leaf is absent but the parent path exists" do
        action = build_axn do
          expects :address, type: Hash
          expects :postcode, on: "address.billing", type: String, optional: true
        end

        expect(action.call(address: { billing: {} })).to be_ok
      end

      it "still raises when the root of the path is not declared" do
        expect do
          build_axn do
            expects :postcode, on: "address.billing", type: String
          end
        end.to raise_error(ArgumentError, /no such method|address/)
      end

      it "rejects default: combined with a nested on:" do
        expect do
          build_axn do
            expects :address, type: Hash
            expects :postcode, on: "address.billing", default: "00000"
          end
        end.to raise_error(ArgumentError, /not supported with a nested/)
      end

      it "rejects a falsey default: (e.g. default: false) combined with a nested on:" do
        expect do
          build_axn do
            expects :settings, type: Hash
            expects :enabled, on: "settings.flags", type: :boolean, default: false
          end
        end.to raise_error(ArgumentError, /not supported with a nested/)
      end

      it "rejects preprocess: combined with a nested on:" do
        expect do
          build_axn do
            expects :address, type: Hash
            expects :postcode, on: "address.billing", preprocess: ->(_value) { "static" }
          end
        end.to raise_error(ArgumentError, /not supported with a nested/)
      end

      it "rejects sensitive: combined with a nested on: (the log filter can't redact a nested path)" do
        expect do
          build_axn do
            expects :address, type: Hash
            expects :ssn, on: "address.billing", sensitive: true
          end
        end.to raise_error(ArgumentError, /not supported with a nested/)
      end
    end

    context "with objects rather than hashes" do
      let(:action) do
        build_axn do
          expects :foo
          expects :bar, on: :foo
        end
      end
      let(:foo) { double(bar: 3) }

      it "validates" do
        expect(action.call(foo:)).to be_ok
      end
    end

    context "with a subfield name that collides with a Hash/Enumerable method" do
      let(:action) do
        build_axn do
          expects :address, type: Hash
          expects :zip, on: :address, type: String
          exposes :echoed

          def call
            expose :echoed, zip
          end
        end
      end

      it "reads the key rather than calling the method" do
        result = action.call(address: { zip: "12345" })
        expect(result).to be_ok
        expect(result.echoed).to eq("12345")
      end

      it "also reads the key through a nested (dotted) on: path" do
        action = build_axn do
          expects :address, type: Hash
          expects :zip, on: "address.billing", type: String
          exposes :echoed

          def call
            expose :echoed, zip
          end
        end

        result = action.call(address: { billing: { zip: "12345" } })
        expect(result).to be_ok
        expect(result.echoed).to eq("12345")
      end
    end

    context "sensitive subfields" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :password, on: :user_data, sensitive: true
          expects :email, on: :user_data
        end
      end

      let(:user_data) { { password: "secret123", email: "user@example.com" } }
      subject(:result) { action.call(user_data:) }

      context "when validation passes" do
        it "succeeds" do
          expect(result).to be_ok
        end

        it "filters sensitive subfield in internal context inspect" do
          # Create a simple action to access internal context
          simple_action = build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data
            exposes :internal_ctx

            def call
              expose :internal_ctx, internal_context
            end
          end

          result = simple_action.call(user_data:)
          expect(result.internal_ctx.inspect).to include("password")
          expect(result.internal_ctx.inspect).to include("user@example.com")

          # Sensitive subfields should now be filtered in inspection
          expect(result.internal_ctx.inspect).to include("[FILTERED]")
          expect(result.internal_ctx.inspect).not_to include("secret123")
        end

        it "filters sensitive subfield in execution_context" do
          # Test that execution_context filters sensitive subfields
          instance = action.send(:new, user_data:)
          exec_ctx = instance.execution_context

          expect(exec_ctx[:inputs][:user_data]).to include(password: "[FILTERED]")
          expect(exec_ctx[:inputs][:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(exec_ctx.to_s).not_to include("secret123")
          expect(exec_ctx[:inputs][:user_data][:password]).not_to eq("secret123")
        end

        it "filters sensitive subfield in result inspect" do
          expect(result.inspect).to eq(
            "#<Axn::Result [OK]>",
          )
        end
      end

      context "when validation fails" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
          end
        end

        let(:user_data) { { password: "secret123", email: "invalid-email" } }

        it "fails with validation error" do
          expect(result).not_to be_ok
          expect(result.exception).to be_a(Axn::InboundValidationError)
        end

        it "filters sensitive subfield in error context" do
          # Test that sensitive data is filtered in error logging by checking execution_context
          instance = action.send(:new, user_data:)
          exec_ctx = instance.execution_context

          expect(exec_ctx[:inputs][:user_data]).to include(password: "[FILTERED]")
          expect(exec_ctx[:inputs][:user_data]).to include(email: "invalid-email")

          # Ensure the actual sensitive value is NOT present
          expect(exec_ctx.to_s).not_to include("secret123")
          expect(exec_ctx[:inputs][:user_data][:password]).not_to eq("secret123")
        end
      end

      context "with exception handling" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data

            def call
              raise "Some internal error"
            end
          end
        end

        before do
          allow(Axn.config).to receive(:on_exception)
        end

        it "filters sensitive subfield in exception context" do
          expect(Axn.config).to receive(:on_exception).with(
            anything,
            action:,
            context: hash_including(
              inputs: {
                user_data: { password: "[FILTERED]", email: "user@example.com" },
              },
              outputs: {},
            ),
          ).and_call_original

          expect(result).not_to be_ok
        end
      end

      context "with automatic logging" do
        let(:action) do
          build_axn do
            expects :user_data
            expects :password, on: :user_data, sensitive: true
            expects :email, on: :user_data

            auto_log :info
          end
        end

        it "filters sensitive subfield in logging context" do
          # Test that inputs_for_logging filters sensitive subfields for automatic logging
          instance = action.send(:new, user_data:)
          filtered_inputs = instance.send(:inputs_for_logging)

          expect(filtered_inputs[:user_data]).to include(password: "[FILTERED]")
          expect(filtered_inputs[:user_data]).to include(email: "user@example.com")

          # Ensure the actual sensitive value is NOT present
          expect(filtered_inputs.to_s).not_to include("secret123")
          expect(filtered_inputs[:user_data][:password]).not_to eq("secret123")
        end
      end
    end
  end

  context "subfield preprocessing" do
    let(:user_data) do
      {
        name: "John Doe",
        email: "  JOHN@EXAMPLE.COM  ",
        profile: {
          bio: "Software developer",
          website: "https://example.com",
        },
      }
    end

    context "when preprocessing is successful" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(email) { email.downcase.strip }
          expects :name, on: :user_data # No preprocessing
          expects "profile.bio", on: :user_data, preprocess: lambda(&:upcase) # Nested subfield from profile.bio
          expects "profile.website", on: :user_data, preprocess: ->(url) { url.gsub(%r{^https?://}, "") } # Nested subfield from profile.website
        end
      end

      it "preprocesses subfield values" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that preprocessing was applied by accessing the action instance
        expect(result.__action__.email).to eq("john@example.com")
        expect(result.__action__.name).to eq("John Doe") # Unchanged

        # Check nested subfield preprocessing by accessing the context data
        user_data = result.__action__.user_data

        # Check if the nested structure is correctly updated (symbol keys)
        expect(user_data.dig(:profile, :bio)).to eq("SOFTWARE DEVELOPER") # Should be preprocessed
        expect(user_data.dig(:profile, :website)).to eq("example.com") # Should be preprocessed
      end

      it "preserves original parent field structure" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # The parent field should still be accessible
        expect(result.__action__.user_data).to be_a(Hash)
        expect(result.__action__.user_data[:name]).to eq("John Doe")
      end
    end

    context "when preprocessing fails" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(email) { Date.parse(email) }
        end
      end

      it "raises PreprocessingError" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
        expect(result.exception.message).to include("Error preprocessing subfield 'email' on 'user_data'")
      end

      it "preserves the original exception as cause" do
        result = action.call(user_data:)
        expect(result.exception.cause).to be_a(ArgumentError)
        expect(result.exception.cause.message).to include("invalid date")
      end
    end

    context "when fail! is called in subfield preprocess block" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { fail!("Invalid email") }
        end
      end

      it "fails with Axn::Failure" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::Failure)
        expect(result.exception).not_to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the error message" do
        result = action.call(user_data:)
        expect(result.error).to eq("Invalid email")
      end

      it "triggers on_failure handlers, not on_exception" do
        failure_called = false
        exception_called = false

        action = build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { fail!("Invalid email") }

          on_failure { failure_called = true }
          on_exception { exception_called = true }
        end

        action.call(user_data:)
        expect(failure_called).to be true
        expect(exception_called).to be false
      end
    end

    context "when done! is called in subfield preprocess block" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { done!("Early completion") }
        end
      end

      it "returns a successful result" do
        result = action.call(user_data:)
        expect(result).to be_ok
      end

      it "sets the success message" do
        result = action.call(user_data:)
        expect(result.success).to eq("Early completion")
      end

      it "triggers on_success handlers" do
        success_called = false

        action = build_axn do
          expects :user_data
          expects :email, on: :user_data, preprocess: ->(_email) { done!("Early completion") }

          on_success { success_called = true }
        end

        result = action.call(user_data:)
        expect(result).to be_ok
        expect(success_called).to be true
      end
    end

    context "with object-based parent fields" do
      let(:user_object) do
        Struct.new(:name, :email).new("John Doe", "JOHN@EXAMPLE.COM")
      end

      let(:action) do
        build_axn do
          expects :user
          expects :email, on: :user, preprocess: lambda(&:downcase)
        end
      end

      it "handles object-based parent fields with setter methods" do
        result = action.call(user: user_object)
        expect(result).to be_ok

        expect(result.__action__.email).to eq("john@example.com")
        expect(user_object.email).to eq("john@example.com") # Modified in place
      end
    end
  end

  context "subfield defaults" do
    let(:user_data) do
      {
        name: "John Doe",
        email: "john@example.com",
        profile: {
          bio: "Software developer",
          website: "https://example.com",
        },
      }
    end

    context "when defaults are applied successfully" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: "No bio provided"
          expects "profile.website", on: :user_data, default: "No website"
          expects "profile.location", on: :user_data, default: "Unknown location"
        end
      end

      it "applies defaults for missing simple subfields" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the default was applied
        expect(result.__action__.bio).to eq("No bio provided")
      end

      it "applies defaults for missing nested subfields" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the default was applied to nested structure
        user_data = result.__action__.user_data
        expect(user_data.dig(:profile, :location)).to eq("Unknown location")
      end

      it "does not apply defaults when field already exists" do
        # Add bio to user_data to test that existing values are preserved
        user_data[:bio] = "Existing bio"

        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that existing value was preserved
        expect(result.__action__.bio).to eq("Existing bio")
      end

      it "applies defaults when field is explicitly nil" do
        # Set bio to nil explicitly to test nil value handling
        user_data[:bio] = nil

        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that default was applied for nil value
        expect(result.__action__.bio).to eq("No bio provided")
      end

      it "applies defaults when field is missing" do
        # Remove bio key entirely to test missing key handling
        user_data.delete(:bio)

        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that default was applied for missing key
        expect(result.__action__.bio).to eq("No bio provided")
      end
    end

    context "with callable defaults" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :bio, on: :user_data, default: -> { "Generated bio #{Time.now.to_i}" }
          expects "profile.timestamp", on: :user_data, default: -> { "Generated at #{Time.now.to_i}" }
        end
      end

      it "evaluates callable defaults in action context" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that callable defaults were evaluated
        bio = result.__action__.bio
        expect(bio).to match(/Generated bio \d+/)

        user_data = result.__action__.user_data
        timestamp = user_data.dig(:profile, :timestamp)
        expect(timestamp).to match(/Generated at \d+/)
      end
    end

    context "with object-based parent fields" do
      let(:user_object) do
        Struct.new(:name, :email, :bio).new("John Doe", "john@example.com", nil)
      end

      let(:action) do
        build_axn do
          expects :user_object
          expects :bio, on: :user_object, default: "Default bio", type: String
        end
      end

      it "applies defaults to object-based parent fields" do
        result = action.call(user_object:)
        expect(result).to be_ok

        # Check that the default was applied to the object
        expect(result.__action__.bio).to eq("Default bio")
        expect(user_object.bio).to eq("Default bio")
      end
    end

    context "when parent field is missing" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :missing_profile, allow_nil: true, type: Hash # Declare the parent field as optional
          expects :bio, on: :missing_profile, default: "Default bio", type: String
        end
      end

      it "creates parent field and applies default" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the parent field was created and default applied
        expect(result.__action__.missing_profile).to eq({ bio: "Default bio" })
      end
    end

    context "when default application fails" do
      let(:action) do
        build_axn do
          expects :user_data
          expects :missing_field, on: :user_data, default: -> { raise "Default error" }, type: String
        end
      end

      it "fails with DefaultAssignmentError when default application fails" do
        result = action.call(user_data:)
        expect(result).not_to be_ok
        expect(result.exception).to be_a(Axn::ContractViolation::DefaultAssignmentError)
        expect(result.exception.message).to include("Error applying default for subfield 'missing_field' on 'user_data'")
        expect(result.exception.cause).to be_a(RuntimeError)
        expect(result.exception.cause.message).to eq("Default error")
      end
    end

    context "subfield defaults with blank values" do
      let(:user_data) do
        {
          name: "John Doe",
          email: "john@example.com",
          profile: {
            bio: "Software developer",
            website: "https://example.com",
          },
        }
      end

      shared_examples "subfield default behavior with blank values" do |default_value, allow_blank, expected_behavior|
        let(:action) do
          build_axn do
            expects :user_data
            expects :bio, on: :user_data, default: default_value, allow_blank:, type: String
            expects "profile.description", on: :user_data, default: default_value, allow_blank:, type: String
          end
        end

        context "when subfield is missing" do
          it "applies default and #{expected_behavior[:missing]}" do
            result = action.call(user_data:)
            if expected_behavior[:missing][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq default_value
              expect(user_data.dig(:profile, :description)).to eq default_value
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield is explicitly nil" do
          before do
            user_data[:bio] = nil
            user_data[:profile][:description] = nil
          end

          it "applies default and #{expected_behavior[:nil]}" do
            result = action.call(user_data:)
            if expected_behavior[:nil][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq default_value
              expect(user_data.dig(:profile, :description)).to eq default_value
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield has blank string value" do
          before do
            user_data[:bio] = ""
            user_data[:profile][:description] = ""
          end

          it "preserves existing blank value and #{expected_behavior[:blank]}" do
            result = action.call(user_data:)
            if expected_behavior[:blank][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq ""
              expect(user_data.dig(:profile, :description)).to eq ""
            else
              expect(result).not_to be_ok
              expect(result.exception).to be_a(Axn::InboundValidationError)
              expect(result.exception.message).to include("can't be blank")
            end
          end
        end

        context "when subfield has non-blank value" do
          before do
            user_data[:bio] = "Existing bio"
            user_data[:profile][:description] = "Existing description"
          end

          it "preserves existing value and passes validation" do
            result = action.call(user_data:)
            expect(result).to be_ok
            expect(result.__action__.bio).to eq "Existing bio"
            expect(user_data.dig(:profile, :description)).to eq "Existing description"
          end
        end
      end

      context "with blank string default and allow_blank: true" do
        include_examples "subfield default behavior with blank values", "", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with blank string default and allow_blank: false" do
        include_examples "subfield default behavior with blank values", "", false, {
          missing: { success: false, description: "fails validation" },
          nil: { success: false, description: "fails validation" },
          blank: { success: false, description: "fails validation" },
        }
      end

      context "with non-blank default and allow_blank: true" do
        include_examples "subfield default behavior with blank values", "Default bio", true, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: true, description: "passes validation (does not apply default)" },
        }
      end

      context "with non-blank default and allow_blank: false" do
        include_examples "subfield default behavior with blank values", "Default bio", false, {
          missing: { success: true, description: "passes validation" },
          nil: { success: true, description: "passes validation" },
          blank: { success: false, description: "fails validation" },
        }
      end
    end
  end

  describe "contradiction rejections (PRO-2877)" do
    # A minimal model target; the raise fires at declaration, before any resolution.
    # rubocop:disable Lint/ConstantDefinitionInBlock
    class FakeModel; def self.find(_id) = new; end
    # rubocop:enable Lint/ConstantDefinitionInBlock

    describe "family 4: dotted-name model: subfield" do
      it "raises, pointing at the reader spelling" do
        expect do
          build_axn do
            expects :payload
            expects "org.company", on: :payload, model: FakeModel
          end
        end.to raise_error(
          ArgumentError,
          'a dotted-name model: subfield (["org.company"] with on: payload) has no consumable id — ' \
          "a dotted subfield name generates no reader, so the id-to-record lookup never runs. " \
          'Use the reader spelling instead: expects :company, on: "payload.org", model: ...',
        )
      end

      it "does not raise for the reader spelling (dotted on:, single-level name)" do
        expect do
          build_axn do
            expects :payload
            expects :company, on: "payload.org", model: FakeModel
          end
        end.not_to raise_error
      end
    end

    describe "verify-before-commit" do
      it "does not commit the rejected subfield when the contradiction error is rescued" do
        klass = build_axn do
          expects :payload, type: Hash, allow_nil: true
        end

        # A rescued declaration (Rails reload, metaprogramming) must not leave the rejected subfield
        # behind — the contract is validated on the prospective config set BEFORE the configs are committed.
        expect do
          klass.class_eval do
            expects :id, on: "payload.meta", type: Integer
          end
        end.to raise_error(ArgumentError, /nil-tolerant/)

        expect(klass.subfield_configs.map(&:field)).not_to include(:id)
      end

      it "does not leave an orphaned reader when the contradiction error is rescued" do
        klass = build_axn do
          expects :payload, type: Hash, allow_nil: true
        end

        expect do
          klass.class_eval do
            expects :thing, on: "payload.meta", type: Integer
          end
        end.to raise_error(ArgumentError, /nil-tolerant/)

        # Reader generation is deferred until after every declaration check passes, so a rejected subfield
        # leaves no orphaned reader method or recorded reader name — a corrected retry won't collide with
        # the duplicate-reader guard, and no unvalidated reader is callable.
        expect(klass.method_defined?(:thing)).to be(false)
        expect(klass._generated_subfield_reader_names).not_to include(:thing)
      end
    end

    describe "family 1: nil-tolerant ancestor + required descendant" do
      it "raises when a nil-tolerant top-level parent has a required deep subfield" do
        expect do
          build_axn do
            expects :payload, type: Hash, allow_nil: true
            expects :id, on: "payload.meta", type: Integer
          end
        end.to raise_error(
          ArgumentError,
          "expects :payload is declared nil-tolerant (allow_nil:/optional:) but :id (on: payload.meta) " \
          "is required — a nil or omitted :payload can never satisfy it. " \
          "Drop allow_nil:/optional: on :payload, or make :id optional on every declaration that reaches it.",
        )
      end

      it "raises when an intermediate subfield is optional: but its subtree requires presence" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, type: Hash, optional: true
            expects :id, on: "payload.meta", type: Integer
          end
        end.to raise_error(ArgumentError, /:meta .* but :id \(on: payload\.meta\) is required/)
      end

      it "does not raise when the required descendant is itself optional" do
        expect do
          build_axn do
            expects :payload, type: Hash, allow_nil: true
            expects :id, on: "payload.meta", type: Integer, optional: true
          end
        end.not_to raise_error
      end

      it "does not raise when the parent is required (no nil-tolerance)" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :id, on: "payload.meta", type: Integer
          end
        end.not_to raise_error
      end

      it "raises when a defaulted intermediate can't rescue a required descendant under a " \
         "non-object (type: Array) nil-tolerant ancestor" do
        # Executor#_materialize_object_parent! refuses to inject `{}` for a non-object parent (type:
        # Array, a mixed union) — so a nil :payload never materializes, :meta's default never applies,
        # and :id is genuinely stranded. The defaulted-node shield must NOT suppress this.
        expect do
          build_axn do
            expects :payload, type: Array, allow_nil: true
            expects :meta, on: :payload, type: Hash, default: { id: 1 }
            expects :id, on: :meta, type: Integer
          end
        end.to raise_error(ArgumentError, /:payload is declared nil-tolerant.*:id .* is required/)
      end

      it "does not raise when a defaulted intermediate rescues a required descendant under an " \
         "object-shaped (type: Hash) nil-tolerant ancestor" do
        # Here a nil :payload CAN be materialized as `{}` by the executor, :meta's default then applies,
        # and :id is satisfied — the shield correctly suppresses the would-be family-1 contradiction.
        expect do
          build_axn do
            expects :payload, type: Hash, allow_nil: true
            expects :meta, on: :payload, type: Hash, default: { id: 1 }
            expects :id, on: :meta, type: Integer
          end
        end.not_to raise_error
      end

      it "does not raise when a nil-tolerant intermediate with its OWN usable default rescues its subtree" do
        # :meta is BOTH nil-tolerant (optional:) AND defaulted — its own default materializes it, so a
        # required :id below is never stranded even though the parent :payload is not itself nil-tolerant.
        # A shielded node must not register its OWN nil-tolerance as a stranding ancestor for its children.
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :meta, on: :payload, optional: true, default: { id: 1 }
            expects :id, on: :meta, type: Integer
          end
        end.not_to raise_error
      end

      it "still raises for a nil-tolerant model parent with its own default (a model default does not rescue)" do
        # A model node's materialized default is a non-record value ModelValidator rejects, so — unlike a
        # plain object default — it rescues nothing: the model node stays a nil-tolerant ancestor and a
        # required subfield under it is genuinely stranded on omission.
        expect do
          build_axn do
            expects :company, model: FakeModel, optional: true, default: { id: 1 }
            expects :name, on: :company, type: String
          end
        end.to raise_error(ArgumentError, /:company is declared nil-tolerant.*:name .* is required/)
      end
    end

    describe "family 2: non-object shape member + colliding deep subfield" do
      it "raises when a deep subfield nests under a non-object (String) shape member" do
        expect do
          build_axn do
            expects :payload, type: Hash do
              field :bar, type: String
            end
            expects "bar.baz", on: :payload, type: String
          end
        end.to raise_error(
          ArgumentError,
          ":bar.baz (on: payload) nests beneath shape member :bar on :payload, which is declared a non-object " \
          "type (String) — a nested subfield has nowhere to live. Make :bar an object-shaped member " \
          "(Hash/:params), or drop the nested subfield.",
        )
      end

      it "does not raise when the colliding shape member is object-shaped" do
        expect do
          build_axn do
            expects :payload, type: Hash do
              field :bar, type: Hash
            end
            expects "bar.baz", on: :payload, type: String
          end
        end.not_to raise_error
      end

      it "names the true (inner) immediate carrier when a shape member name repeats at two depths" do
        expect do
          build_axn do
            expects :payload, type: Hash do
              field :bar, type: Hash do
                field :bar, type: String
              end
            end
            expects "bar.bar.baz", on: :payload
          end
        end.to raise_error(
          ArgumentError,
          ":bar.bar.baz (on: payload) nests beneath shape member :bar on :bar, which is declared a non-object " \
          "type (String) — a nested subfield has nowhere to live. Make :bar an object-shaped member " \
          "(Hash/:params), or drop the nested subfield.",
        )
      end
    end

    describe "family 3: nil-tolerant model: parent + applied-default descendant" do
      it "raises when a nil-tolerant model parent has a defaulted subfield" do
        expect do
          build_axn do
            expects :company, model: FakeModel, allow_nil: true
            expects :name, on: :company, default: "Acme"
          end
        end.to raise_error(
          ArgumentError,
          "expects :company is a nil-tolerant model: (allow_nil:) but :name (on: company) carries a default " \
          "— the default materializes an empty object under :company, which the model validator rejects as " \
          "not a record, so :company can never be omitted. Drop allow_nil: on :company, or drop the subfield default.",
        )
      end

      it "counts a Proc default (materialization fires before the Proc runs)" do
        # `optional: true` keeps this isolated to family 3: a bare Proc default (no allow_nil:/optional:)
        # already trips family 1 first (self_required? treats a Proc as unusable, per usable_default?'s
        # side-effect-free design — it never calls the Proc to see whether the result would satisfy
        # presence), which is a genuine, separate contradiction and not what this example targets.
        expect do
          build_axn do
            expects :company, model: FakeModel, allow_nil: true
            expects :name, on: :company, default: -> { "x" }, optional: true
          end
        end.to raise_error(ArgumentError, /nil-tolerant model:/)
      end

      it "does not raise for a required model parent with a defaulted subfield" do
        expect do
          build_axn do
            expects :company, model: FakeModel
            expects :name, on: :company, default: "Acme"
          end
        end.not_to raise_error
      end
    end
  end
end
