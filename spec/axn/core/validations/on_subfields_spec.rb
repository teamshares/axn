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

    let(:action) do
      build_axn do
        expects :foo
        expects :bar, :baz, on: :foo
        exposes :output

        def call
          expose output: qux
        end
      end.tap do |action|
        action.expects :qux, on: :bar
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

    context "with allow_blank/allow_nil/optional as the only constraint (no other validator)" do
      # Mirrors top-level `expects :x, allow_blank: true`, which builds an optional, unconstrained
      # field. The parser leaves an empty validations hash in this case (allow_blank/allow_nil are
      # merged into existing validators, of which there are none), so the subfield validator must
      # not call ActiveModel `validates` with zero validators.
      %i[allow_blank allow_nil optional].each do |opt|
        context "with #{opt}: true only" do
          let(:action) do
            build_axn do
              expects :foo, type: Hash
              expects :bar, on: :foo, opt => true
              exposes :val, allow_nil: true
              def call = expose(val: bar)
            end
          end

          it "builds and runs an optional, unconstrained subfield" do
            result = action.call(foo: { bar: "hello" })
            expect(result).to be_ok
            expect(result.val).to eq("hello")
          end

          it "accepts a missing subfield value" do
            # non-blank parent that simply lacks :bar (an empty {} would trip the parent's own presence)
            expect(action.call(foo: { other: 1 })).to be_ok
          end
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

      context "with a required parent and a required subfield" do
        # The parent is required (not nil-tolerant): a nil-tolerant parent with a bare required subfield is
        # now rejected at declaration under PRO-2889 (see subfield_contradictions_spec). A nil value on the
        # required parent still surfaces a clean InboundValidationError, never a bare RuntimeError.
        let(:action) do
          build_axn do
            expects :payload
            expects :name, on: :payload, type: String
            def call = nil
          end
        end

        it "surfaces a clean InboundValidationError (not a bare RuntimeError)" do
          result = action.call(payload: nil)
          expect(result).not_to be_ok
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("can't be blank")
          expect(result.exception.message).not_to match(/Unclear how to extract/)
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
          # A nil/absent parent means the subfield is absent — the preprocess is skipped, rather than
          # synthesizing the parent. (A present-but-empty `{}` parent differs: the subfield is present there,
          # so the preprocess runs and its result — "" — is resolved on the read path for the reader.)
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

        it "runs the subfield preprocess normally when the required parent IS provided (non-blank)" do
          # A present-but-empty `{}` is blank and fails the parent's own presence — a subfield preprocess no
          # longer launders it non-blank. A genuinely-present parent passes, and the preprocess still runs.
          expect(action.call(payload: { other: 1 })).to be_ok
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

        it "evaluates the value-level Proc default on the nil parent without materializing it (PRO-2889)" do
          # PRO-2889: validation reads each subfield through its reader, which resolves the value-level
          # default — so the Proc runs even under a nil non-object parent (the reader's resolved value is
          # the default). The write-back pass still refuses to materialize the parent, so `items` stays nil.
          ran = []
          action = build_axn do
            expects :items, type: Array, optional: true
            expects :count, on: :items, optional: true, type: Integer, default: -> { ran.push(5).last }
            exposes :parent, optional: true, allow_nil: true
            def call = expose(parent: items)
          end
          result = action.call(items: nil)
          expect(result).to be_ok
          expect(ran).to eq([5])
          expect(result.parent).to be_nil
        end

        it "does not raise on a dotted-on: subfield default when the nil parent isn't materialized" do
          action = build_axn do
            expects :items, type: Array, optional: true
            # `first` is a real Array reader, so the segment is answerable at declaration
            expects :b, on: "items.first", optional: true, type: String, default: "x"
            def call = nil
          end
          result = action.call(items: nil)
          expect(result).to be_ok
          expect(result.exception).to be_nil
        end
      end

      context "with a dotted path crossing a nested Array (PRO-2886)" do
        # The reader spelling (`:count on :items`) and the dotted spelling (`"items.count" on :payload`)
        # name the same wire path and must resolve identically — reaching Array#count on the nested
        # Array rather than digging a String key into it.
        it "resolves a nested Array method the same via the reader and the dotted spelling" do
          # Reader spelling exposes the resolved Array#count directly. Reaching an Array method is
          # method dispatch, so both spellings opt in with `method_call: true` (PRO-2898).
          reader = build_axn do
            expects :payload, type: Hash
            expects :items, on: :payload, type: Array
            expects :count, on: :items, type: Integer, method_call: true
            exposes :n, allow_nil: true
            def call = expose(n: count)
          end
          # The dotted on: spelling names the same wire path via a single declaration. A required
          # `type: Integer` on the path passes only if it resolves to the Integer 3 (before the fix it
          # resolved to nil → validation failure), so validation success stands in for the resolved value.
          dotted = build_axn do
            expects :payload, type: Hash
            expects :count, on: "payload.items", type: Integer, method_call: true
            def call = nil
          end

          expect(reader.call(payload: { items: [10, 20, 30] }).n).to eq(3)
          expect(dotted.call(payload: { items: [10, 20, 30] })).to be_ok
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
        # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as
        # a rescue); the runtime is unchanged — the Proc still materializes `{}`, so the required shape member
        # is enforced on an omitted/nil parent exactly as before.
        let(:action) do
          build_axn do
            expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
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

      context "with no validators beyond presence-tolerance (optional: true only)" do
        # `optional:` alone leaves the parsed validations empty; `validates` with an empty set would
        # raise "You need to supply at least one validation" on EVERY call. An empty set means
        # nothing to enforce — matching a top-level field declared the same way.
        let(:action) do
          build_axn do
            expects :user, type: Hash
            expects :nickname, on: :user, optional: true
            exposes :got, optional: true

            def call = expose(got: nickname)
          end
        end

        it "runs and reads the subfield when present" do
          result = action.call(user: { nickname: "kd" })
          expect(result).to be_ok
          expect(result.got).to eq("kd")
        end

        it "runs when the subfield is absent" do
          expect(action.call(user: { other: 1 })).to be_ok
        end
      end

      context "with a symbol-referenced validation argument" do
        # Symbol arguments (e.g. `inclusion: { in: :allowed_sizes }`) resolve against the action
        # instance for subfields exactly as they do for top-level fields (shared Validation::Base
        # delegation).
        let(:action) do
          build_axn do
            expects :order, type: Hash
            expects :size, on: :order, type: String, inclusion: { in: :allowed_sizes }

            def allowed_sizes = %w[s m l]
            def call = nil
          end
        end

        it "accepts a value the action method allows" do
          expect(action.call(order: { size: "m" })).to be_ok
        end

        it "rejects a value outside the action method's set" do
          expect(action.call(order: { size: "xl" })).not_to be_ok
        end
      end

      context "readers: (removed kwarg)" do
        it "raises the generic unknown-key error (the kwarg is gone, not tombstoned)" do
          expect do
            build_axn do
              expects :payload
              expects :bar, on: :payload, readers: false
            end
          end.to raise_error(ArgumentError, /Unknown key\(s\) :readers in field declaration/)
        end

        # Every subfield generates a reader now, so the duplicate-sub-keys collision check fires
        # for an inherited-method name — nothing can slip past it readerless.
        it "raises the duplicate-sub-keys error for a subfield named :class" do
          expect do
            build_axn do
              expects :payload
              expects :class, on: :payload
            end
          end.to raise_error(ArgumentError, /expects does not support duplicate sub-keys \(i\.e\. `class` is already defined\).*as:/)
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
          expects :baz, on: "foo.bar"
        end
      end

      it "validates" do
        expect(action.call(foo: { bar: { baz: 3 } })).to be_ok
        expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end

      context "with duplicate sub-keys" do
        it "raises (the reader name is already claimed)" do
          expect do
            build_axn do
              expects :foo
              expects :bar, on: :foo
            end.expects :foo, on: :bar
          end.to raise_error(ArgumentError, /expects does not support duplicate sub-keys \(i\.e\. `foo` is already defined\).*as: :bar_foo/)
        end

        it "resolves via as: (rename instead of the removed readers: false suppression)" do
          action = build_axn do
            expects :foo
            expects :bar, on: :foo
            expects :foo, on: :bar, as: :inner_foo
          end

          expect(action.call(foo: { bar: { foo: 3 } })).to be_ok
          expect(action.call(foo: { bar: { baz: 3 } })).not_to be_ok
        end

        it "treats string and symbol on: as the same route (a genuine duplicate, not a merge)" do
          # `on: :payload` and `on: "payload"` name the SAME parent (the tree splits `on:` via to_s), so
          # the same wire key under both is a true duplicate even when the second renames its reader.
          expect do
            build_axn do
              expects :payload, type: Hash
              expects :x, on: :payload
              expects :x, on: "payload", as: :x2
            end
          end.to raise_error(Axn::DuplicateFieldError, /x/)
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

      describe "default:/preprocess:/sensitive: with a nested on: (kwarg parity)" do
        it "applies a default through a nested on: path, materializing the intermediate" do
          action = build_axn do
            expects :address, type: Hash
            expects :postcode, on: "address.billing", optional: true, default: "00000"
            exposes :got, optional: true

            def call = expose(got: postcode)
          end

          expect(action.call(address: { other: 1 }).got).to eq("00000")
          expect(action.call(address: { billing: { postcode: "11111" } }).got).to eq("11111")
        end

        it "applies a falsey default (default: false) through a nested on: path" do
          action = build_axn do
            expects :settings, type: Hash
            expects :enabled, on: "settings.flags", optional: true, type: :boolean, default: false
            exposes :got, optional: true, allow_nil: true, type: :boolean

            def call = expose(got: enabled)
          end

          expect(action.call(settings: { other: 1 }).got).to be(false)
        end

        it "resolves a nested default value-level under an absent parent without materializing the chain" do
          action = build_axn do
            expects :address, type: Hash, optional: true, allow_nil: true
            expects :postcode, on: "address.billing", optional: true, default: "00000"
            exposes :parent, :got, optional: true, allow_nil: true

            def call = expose(parent: address, got: postcode)
          end

          result = action.call
          expect(result.got).to eq("00000") # child resolves its default on the read path
          expect(result.parent).to be_nil   # parent is never synthesized
        end

        it "skips a nested default when an absent intermediate ancestor is declared non-object" do
          action = build_axn do
            expects :payload, type: Hash
            expects :flags, on: :payload, optional: true, allow_nil: true, type: Array
            expects :first, on: "payload.flags", optional: true, default: "x"
            exposes :parent, optional: true

            def call = expose(parent: payload)
          end

          result = action.call(payload: { other: 1 })
          expect(result).to be_ok
          expect(result.parent).to eq({ other: 1 })
        end

        it "never synthesizes an absent model: parent (a default there would clobber a valid id-based call)" do
          model = Struct.new(:id, :timezone) do
            def self.find(id) = new(id, "America/New_York")
            def self.name = "FakeSynthModel"
          end

          action = build_axn do
            expects :company, model: { klass: model }
            expects :timezone, on: :company, optional: true, default: "UTC"
            exposes :got, optional: true

            def call = expose(got: timezone)
          end

          # Supplied by id: the record resolves through company_id — synthesizing { timezone: "UTC" }
          # into provided_data[:company] would make the model resolver prefer that hash over the id.
          result = action.call(company_id: 7)
          expect(result).to be_ok
          expect(result.got).to eq("America/New_York")
        end

        it "skips a nested default when the implicit intermediate collides with a non-object shape member" do
          # `settings` is a non-nestable `[Hash, String]` member (the String branch blocks nesting, the Hash
          # branch keeps the segment answerable at declaration) — synthesizing `{ enabled: true }` there would turn a
          # validly-absent optional member into a shape violation, so the default is skipped (the same
          # member-nestability rule the schema's drop pass applies).
          action = build_axn do
            expects :payload, type: Hash do
              field :settings, type: [Hash, String], optional: true
            end
            expects :enabled, on: "payload.settings", optional: true, type: :boolean, default: true
            exposes :parent, optional: true

            def call = expose(parent: payload)
          end

          result = action.call(payload: { other: 1 })
          expect(result).to be_ok
          expect(result.parent).to eq({ other: 1 })
        end

        it "drops a nested preprocess result when the implicit intermediate collides with a non-object shape member" do
          # Same synthesis gate as defaults: the write would have to create `settings` as an object where the
          # shape declares a non-nestable `[Hash, String]` member, so the result has nowhere to land and is
          # dropped. (The Hash branch keeps the segment answerable at declaration; the String branch blocks nesting.)
          action = build_axn do
            expects :payload, type: Hash do
              field :settings, type: [Hash, String], optional: true
            end
            expects :flag, on: "payload.settings", optional: true, preprocess: ->(v) { v.nil? ? "computed" : v }
            exposes :parent, optional: true

            def call = expose(parent: payload)
          end

          result = action.call(payload: { other: 1 })
          expect(result).to be_ok
          expect(result.parent).to eq({ other: 1 })
        end

        it "resolves a nested default value-level through an implicit OBJECT-shape intermediate without materializing it" do
          action = build_axn do
            expects :payload, type: Hash do
              field :settings, type: Hash, optional: true
            end
            expects :enabled, on: "payload.settings", optional: true, type: :boolean, default: true
            exposes :parent, :got, optional: true, allow_nil: true

            def call = expose(parent: payload, got: enabled)
          end

          result = action.call(payload: { other: 1 })
          expect(result).to be_ok
          expect(result.got).to be(true)             # child resolves its default on the read path
          expect(result.parent).to eq({ other: 1 })  # parent is not materialized with `settings`
        end

        it "resolves two nested defaults value-level under an absent parent without materializing the intermediate" do
          action = build_axn do
            expects :payload, type: Hash, optional: true, allow_nil: true
            expects :width, on: "payload.dims", optional: true, default: 1
            expects :height, on: "payload.dims", optional: true, default: 2
            exposes :parent, :w, :h, optional: true, allow_nil: true

            def call = expose(parent: payload, w: width, h: height)
          end

          result = action.call
          expect(result.w).to eq(1)         # each child resolves its default on the read path
          expect(result.h).to eq(2)
          expect(result.parent).to be_nil   # the shared intermediate is never materialized
        end

        it "preprocesses through a nested on: path without synthesizing an absent root" do
          action = build_axn do
            expects :address, type: Hash, optional: true, allow_nil: true
            expects :postcode, on: "address.billing", optional: true, preprocess: ->(v) { v.to_s.strip }
            exposes :got, :parent, optional: true, allow_nil: true

            def call = expose(got: postcode, parent: address)
          end

          expect(action.call(address: { billing: { postcode: " 123 " } }).got).to eq("123")

          absent = action.call
          expect(absent).to be_ok
          expect(absent.parent).to be_nil
        end

        it "applies a default on a subfield anchored on another subfield (parent chain via readers)" do
          action = build_axn do
            expects :payload, type: Hash
            expects :settings, on: :payload, optional: true, type: Hash
            expects :enabled, on: :settings, optional: true, type: :boolean, default: true
            exposes :got, optional: true, type: :boolean

            def call = expose(got: enabled)
          end

          expect(action.call(payload: { settings: {} }).got).to be(true)
          expect(action.call(payload: { other: 1 }).got).to be(true)
        end
      end

      describe "canonical parent resolution (on:-spelling equivalence)" do
        # `on: :company` and `on: "payload.company"` name the same wire path; both resolve the parent
        # through the deepest reader-bearing ancestor — for a model: subfield, the resolved RECORD —
        # so the two spellings validate identically.
        let(:model) do
          Struct.new(:id, :name) do
            def self.find(id) = new(id, "Acme #{id}")
            def self.name = "FakeCanonicalModel"
          end
        end

        let(:action_with) do
          lambda do |on_spelling, model_klass|
            build_axn do
              expects :payload, type: Hash
              expects :company, on: :payload, model: { klass: model_klass }
              expects :name, on: on_spelling, type: String, optional: true
              exposes :got, optional: true

              def call = expose(got: name)
            end
          end
        end

        it "resolves the reader spelling through the record" do
          result = action_with.call(:company, model).call(payload: { company_id: 7 })
          expect(result).to be_ok
          expect(result.got).to eq("Acme 7")
        end

        it "resolves the dotted spelling through the SAME record (previously the raw hash)" do
          result = action_with.call("payload.company", model).call(payload: { company_id: 7 })
          expect(result).to be_ok
          expect(result.got).to eq("Acme 7")
        end
      end

      describe "malformed parents (a value that can hold neither key nor method)" do
        # A subfield read from a malformed parent (e.g. `payload: []` where a Hash was declared)
        # resolves as ABSENT rather than raising Extract's UnextractableError — so the parent's own
        # type validation classifies the bad value cleanly, at every pre-validation pass and in
        # validation itself.
        it "classifies via the parent's own validation instead of raising (plain validation)" do
          action = build_axn do
            expects :payload, type: Hash
            expects :note, on: :payload, type: String

            def call = nil
          end

          result = action.call(payload: [])
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("Payload is not a Hash")
          expect(result.exception.message).not_to match(/Unclear how to extract/)
        end

        it "does not let subfield coercion crash on a malformed parent" do
          action = build_axn do
            expects :payload, type: Hash
            expects :starts_on, on: :payload, coerce: Date

            def call = nil
          end

          result = action.call(payload: [])
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("Payload is not a Hash")
        end

        it "does not let subfield preprocess or defaults crash on a malformed parent" do
          action = build_axn do
            expects :payload, type: Hash
            expects :note, on: :payload, optional: true, preprocess: :to_s.to_proc
            expects :flag, on: :payload, optional: true, type: :boolean, default: true

            def call = nil
          end

          result = action.call(payload: [])
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("Payload is not a Hash")
        end

        it "does not let a nested preprocess write-back crash on a malformed root or intermediate" do
          action = build_axn do
            expects :payload, type: Hash
            expects :note, on: "payload.meta", optional: true, preprocess: :to_s.to_proc

            def call = nil
          end

          malformed_root = action.call(payload: [])
          expect(malformed_root.exception).to be_a(Axn::InboundValidationError)
          expect(malformed_root.exception.message).to include("Payload is not a Hash")

          # The root validates (it IS a Hash) but the intermediate is malformed: the write is dropped
          # and the call settles on its declared contract instead of a TypeError.
          malformed_intermediate = action.call(payload: { meta: [] })
          expect(malformed_intermediate).to be_ok
        end

        it "does not let a nested default write-back crash on a malformed intermediate" do
          action = build_axn do
            expects :payload, type: Hash
            expects :note, on: "payload.meta", optional: true, default: "d"
            exposes :parent, optional: true

            def call = expose(parent: payload)
          end

          result = action.call(payload: { meta: [] })
          expect(result).to be_ok
          expect(result.parent).to eq({ meta: [] })
        end

        it "classifies a malformed parent under a model: subfield (the model reader reads it as absent)" do
          model = Struct.new(:id) do
            def self.find(id) = new(id)
            def self.name = "FakeMalformedModel"
          end

          action = build_axn do
            expects :payload, type: Hash
            expects :company, on: :payload, model: { klass: model }

            def call = nil
          end

          result = action.call(payload: "bad")
          expect(result.exception).to be_a(Axn::InboundValidationError)
          expect(result.exception.message).to include("Payload is not a Hash")
        end

        it "settles user-facing when the malformed parent is user_facing (stranded subfield suppressed)" do
          action = build_axn do
            expects :payload, type: Hash, user_facing: "Payload must be an object"
            expects :note, on: :payload, type: String

            def call = nil
          end

          result = action.call(payload: [])
          expect(result.outcome).to be_failure
          expect(result.error).to eq("Payload must be an object")
        end
      end

      describe "stranded-path diagnostics" do
        it "names the first nil intermediate ancestor in the validation report" do
          action = build_axn do
            expects :payload, type: Hash
            expects :city, on: "payload.address", type: String

            def call = nil
          end

          result = action.call(payload: { other: 1 })
          expect(result.outcome).to be_exception
          expect(result.exception.message).to include("City can't be blank")
          expect(result.exception.message).to include("'payload.address' is nil, so nested expectations beneath it cannot be satisfied")
        end

        it "reports one diagnostic per stranded chain, shared across its failing subfields" do
          action = build_axn do
            expects :payload, type: Hash
            expects :city, on: "payload.address", type: String
            expects :zip, on: "payload.address", type: String

            def call = nil
          end

          result = action.call(payload: { other: 1 })
          expect(result.exception.message.scan("'payload.address' is nil").count).to eq(1)
        end

        it "rejects a nil-tolerant top-level parent with a bare required subfield at declaration (no runtime diagnostic needed)" do
          # A plain nil top-level parent stranding a required subfield is now a dead-tolerance contradiction
          # (PRO-2889): it raises at declaration, so the runtime stranded-path diagnostic is never reached.
          expect do
            build_axn do
              expects :payload, type: Hash, optional: true, allow_nil: true
              expects :note, on: :payload

              def call = nil
            end
          end.to raise_error(ArgumentError, /:payload is declared nil-tolerant/)
        end
      end

      describe "sensitive: with a nested on: (kwarg parity)" do
        it "filters a nested sensitive subfield out of the inspect output" do
          action = build_axn do
            expects :address, type: Hash
            expects :ssn, on: "address.billing", optional: true, sensitive: true

            def call = nil
          end

          instance = action.send(:new, address: { billing: { ssn: "123-45-6789" } })
          inspected = instance.internal_context.inspect
          expect(inspected).to include("[FILTERED]")
          expect(inspected).not_to include("123-45-6789")
        end
      end
    end

    context "with objects rather than hashes" do
      # Reading a subfield off a plain object reaches its method — the sharp path — so it opts in with
      # `method_call: true` (PRO-2898).
      let(:action) do
        build_axn do
          expects :foo
          expects :bar, on: :foo, method_call: true
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
          expects :bio, on: "user_data.profile", preprocess: lambda(&:upcase)
          expects :website, on: "user_data.profile", preprocess: ->(url) { url.gsub(%r{^https?://}, "") }
        end
      end

      it "preprocesses subfield values on the read path without mutating the caller's parent" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # The readers return the preprocessed values (resolved value-level on the read path).
        expect(result.__action__.email).to eq("john@example.com")
        expect(result.__action__.name).to eq("John Doe") # unchanged (no preprocess)
        expect(result.__action__.bio).to eq("SOFTWARE DEVELOPER")
        expect(result.__action__.website).to eq("example.com")

        # The caller's parent hash is NOT mutated — preprocess resolves the child value, never writing back.
        expect(user_data.dig(:profile, :bio)).to eq("Software developer")
        expect(user_data.dig(:profile, :website)).to eq("https://example.com")
        expect(user_data[:email]).to eq("  JOHN@EXAMPLE.COM  ")
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

      it "resolves an object-parent subfield's preprocess on the read path without mutating the object" do
        result = action.call(user: user_object)
        expect(result).to be_ok

        expect(result.__action__.email).to eq("john@example.com") # reader returns the preprocessed value
        expect(user_object.email).to eq("JOHN@EXAMPLE.COM") # the caller's object is NOT mutated in place
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
          expects :website, on: "user_data.profile", default: "No website"
          expects :location, on: "user_data.profile", default: "Unknown location"
        end
      end

      it "applies defaults for missing simple subfields" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Check that the default was applied
        expect(result.__action__.bio).to eq("No bio provided")
      end

      it "resolves a nested subfield default value-level without writing it into the parent" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # The reader resolves the default on the read path...
        expect(result.__action__.location).to eq("Unknown location")
        # ...but the caller's nested parent is not mutated with the synthesized key.
        expect(result.__action__.user_data.dig(:profile, :location)).to be_nil
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
          expects :timestamp, on: "user_data.profile", default: -> { "Generated at #{Time.now.to_i}" }
        end
      end

      it "evaluates callable defaults in action context (value-level, not written into the parent)" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # Callable defaults resolve on the read path...
        expect(result.__action__.bio).to match(/Generated bio \d+/)
        expect(result.__action__.timestamp).to match(/Generated at \d+/)

        # ...and the caller's nested parent is not mutated with the generated value.
        expect(result.__action__.user_data.dig(:profile, :timestamp)).to be_nil
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

      it "applies defaults to object-based parent fields without mutating the caller's object (PRO-2889)" do
        result = action.call(user_object:)
        expect(result).to be_ok

        # The reader/validation see the default via the value-level fallback...
        expect(result.__action__.bio).to eq("Default bio")
        # ...but the caller's own object is never mutated (write-path gate: PRO-2889).
        expect(user_object.bio).to be_nil
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

      it "resolves a subfield default value-level without creating the absent parent field" do
        result = action.call(user_data:)
        expect(result).to be_ok

        # The child resolves its default on the read path...
        expect(result.__action__.bio).to eq("Default bio")
        # ...but the absent parent field is not synthesized into existence.
        expect(result.__action__.missing_profile).to be_nil
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
            expects :description, on: "user_data.profile", default: default_value, allow_blank:, type: String
          end
        end

        context "when subfield is missing" do
          it "applies default and #{expected_behavior[:missing]}" do
            result = action.call(user_data:)
            if expected_behavior[:missing][:success]
              expect(result).to be_ok
              expect(result.__action__.bio).to eq default_value
              # The nested default resolves value-level through its `as:` reader...
              expect(result.__action__.description).to eq default_value
              # ...and the caller's own hash is never written by it (read-path resolution, no materialization).
              expect(user_data.dig(:profile, :description)).to be_nil
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
              # The nested default resolves value-level through its `as:` reader...
              expect(result.__action__.description).to eq default_value
              # ...and the caller's own hash is never written by it (the explicit nil stays nil).
              expect(user_data.dig(:profile, :description)).to be_nil
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
              expect(result.__action__.user_data.dig(:profile, :description)).to eq ""
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
            expect(result.__action__.user_data.dig(:profile, :description)).to eq "Existing description"
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

    describe "model: subfield via a dotted on:" do
      it "does not raise for a model: subfield reached via a dotted on:" do
        expect do
          build_axn do
            expects :payload
            expects :company, on: "payload.org", model: FakeModel
          end
        end.not_to raise_error
      end
    end

    describe "verify-before-commit" do
      it "does not commit the rejected subfields when the declaration error is rescued" do
        klass = build_axn do
          expects :settings, type: Hash
        end

        # A rescued declaration (Rails reload, metaprogramming) must not leave the rejected subfields
        # behind — every declaration check runs BEFORE any config is committed or reader generated.
        expect do
          klass.class_eval do
            expects :company, :company_id, on: :settings, model: FakeModel
          end
        end.to raise_error(ArgumentError, /names both :company and its own id companion/)

        expect(klass.subfield_configs.map(&:field)).not_to include(:company, :company_id)
      end

      it "does not leave an orphaned reader when the declaration error is rescued" do
        klass = build_axn do
          expects :settings, type: Hash
        end

        expect do
          klass.class_eval do
            expects :company, :company_id, on: :settings, model: FakeModel
          end
        end.to raise_error(ArgumentError, /names both :company and its own id companion/)

        # Reader generation is deferred until after every declaration check passes, so rejected subfields
        # leave no orphaned reader method — a corrected retry won't collide with the duplicate-reader
        # guard, and no unvalidated reader is callable.
        expect(klass.method_defined?(:company)).to be(false)
        expect(klass.method_defined?(:company_id)).to be(false)
      end
    end

    describe "model: TOP-LEVEL batch naming its own <field>_id companion (parity with the subfield guard)" do
      it "raises at declaration, either order" do
        expect do
          build_axn { expects :company, :company_id, model: FakeModel }
        end.to raise_error(ArgumentError, /names both :company and its own id companion :company_id/)

        expect do
          build_axn { expects :company_id, :company, model: FakeModel }
        end.to raise_error(ArgumentError, /names both :company and its own id companion :company_id/)
      end
    end

    describe "model: subfield batch naming its own <field>_id companion" do
      it "raises: model: applies to every field, so the explicit :<field>_id is a broken second model, either order" do
        # `model:` applies to EVERY field in the batch, so `expects :company, :company_id, on:, model:` makes
        # :company_id a model: subfield too (it would require :company_id_id and reject a raw id), colliding
        # with the raw-id reader :company already generates. There's no working way to pair an explicit id
        # with a model: subfield in one batch — the model: subfield already exposes :company_id — so it's
        # rejected at declaration in either order (declaration options are order-independent).
        expect do
          build_axn do
            expects :settings, type: Hash
            expects :company, :company_id, on: :settings, model: FakeModel
          end
        end.to raise_error(ArgumentError, /names both :company and its own id companion :company_id/)

        expect do
          build_axn do
            expects :settings, type: Hash
            expects :company_id, :company, on: :settings, model: FakeModel
          end
        end.to raise_error(ArgumentError, /names both :company and its own id companion :company_id/)
      end
    end
  end

  describe "value-level default fallback (PRO-2889)" do
    let(:company_class) do
      Class.new do
        attr_accessor :id, :name

        def initialize(id:, name: nil)
          @id = id
          @name = name
        end

        def self.fetch(id) = new(id:)
      end
    end

    before { stub_const("FallbackCompany", company_class) }

    let(:action) do
      build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :nickname, on: :company, type: String, optional: true, default: "anon"
        exposes :nick, allow_nil: true
        def call = expose(nick: nickname)
      end
    end

    it "falls back to the default when the parent record's attribute is nil" do
      expect(action.call(company: FallbackCompany.new(id: 1)).nick).to eq("anon")
    end

    it "falls back when the id-resolved record's attribute is nil" do
      expect(action.call(company_id: 7).nick).to eq("anon")
    end

    it "falls back when the model parent is omitted entirely" do
      expect(action.call.nick).to eq("anon")
    end

    it "falls back when the present parent cannot answer the key" do
      expect(action.call(company: FallbackCompany.new(id: 1, name: "zed")).nick).to eq("anon")
    end

    context "with a record-supplying default on a model subfield" do
      let(:action) do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :company, on: :payload, model: { klass: FallbackCompany, finder: :fetch },
                            optional: true, default: -> { FallbackCompany.new(id: 99, name: "dflt") }
          exposes :got_id, allow_nil: true
          def call = expose(got_id: company&.id)
        end
      end

      it "resolves the defaulted record when the chain is refused" do
        expect(action.call(payload: nil).got_id).to eq(99)
      end
    end

    context "when the parent answers the key" do
      let(:action) do
        build_axn do
          expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, optional: true, default: "anon", method_call: true
          exposes :n, allow_nil: true
          def call = expose(n: name)
        end
      end

      it "prefers a present attribute over the default" do
        expect(action.call(company: FallbackCompany.new(id: 1, name: "zed")).n).to eq("zed")
      end

      it "falls back when the attribute is nil" do
        expect(action.call(company: FallbackCompany.new(id: 1)).n).to eq("anon")
      end
    end

    context "with a REQUIRED defaulted subfield under a nil-tolerant model parent (value-level defaults)" do
      let(:action) do
        build_axn do
          expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: "x", method_call: true
          exposes :n, allow_nil: true
          def call = expose(n: name)
        end
      end

      it "succeeds on omission: the default satisfies validation and the parent stays nil" do
        result = action.call
        expect(result).to be_ok
        expect(result.n).to eq("x")
      end

      it "succeeds on explicit nil" do
        expect(action.call(company: nil)).to be_ok
      end

      it "still reads the record's value when id-resolved" do
        expect(action.call(company_id: 7).n).to eq("x") # fetch returns name: nil → default
      end

      it "rejects a BLANK default a presence validator rejects at declaration (the tolerance is dead)" do
        # A blank default under a nil-tolerant model parent can't rescue omission (presence rejects the
        # blank), so the tolerance is provably dead — PRO-2889 raises at declaration.
        expect do
          build_axn do
            expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String, default: ""
            def call = nil
          end
        end.to raise_error(ArgumentError, /:company is declared nil-tolerant/)
      end
    end

    context "with a defaulted subfield reached via a dotted on: under a refused chain" do
      let(:action) do
        build_axn do
          expects :payload, type: Array, allow_nil: true
          expects :count, on: "payload.first", type: Integer, default: 0 # `first` is a real Array reader, so the segment is answerable at declaration
          def call = nil
        end
      end

      it "validates the fallback value" do
        expect(action.call(payload: nil)).to be_ok
      end
    end

    context "write-path behavior (PRO-2889)" do
      it "never mutates a caller-supplied record with a default" do
        rec = FallbackCompany.new(id: 1)
        action = build_axn do
          expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: "x", method_call: true
          def call = nil
        end
        expect(action.call(company: rec)).to be_ok
        expect(rec.name).to be_nil
      end

      it "evaluates a Proc default exactly once when the write chain is refused" do
        calls = 0
        counter = lambda {
          calls += 1
          "x"
        }
        action = build_axn do
          expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: counter
          exposes :n, allow_nil: true
          def call = expose(n: name)
        end
        expect(action.call.n).to eq("x")
        expect(calls).to eq(1)
      end

      it "resolves a Proc default exactly once per call (memoized across validators)" do
        # Validation resolves the subfield through resolve_value once per ActiveModel validator
        # (type + presence). A model parent refuses the write chain, so the Proc default is the only
        # source; without value-level memoization it ran once per validator.
        calls = 0
        counter = lambda {
          calls += 1
          3
        }
        action = build_axn do
          expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :retries, on: "company.settings", type: Integer, default: counter
          def call = nil
        end
        expect(action.call).to be_ok
        expect(calls).to eq(1)
      end

      it "still materializes fully-object-shaped chains over an explicit nil (unchanged)" do
        action = build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: 42
          exposes :got
          def call = expose(got: id)
        end
        expect(action.call(payload: nil).got).to eq(42)
      end
    end

    context "with a sibling <field>_id default reaching model subfield resolution (PRO-2889)" do
      it "resolves the record via the sibling id default when the object-shaped chain omits the id" do
        # call(payload: {}): the id default materializes meta = {company_id: 42} on the wire, the finder
        # resolves the record, and :name reads off it. (Regression for the wire write-back path — it may
        # already pass pre-fix.)
        action = build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, optional: true, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        # The chain is present but omits the id; the sibling `<field>_id` default supplies the lookup
        # token on the read path (a blank `payload: {}` would now fail the parent's own presence).
        expect(action.call(payload: { meta: {} }).cid).to eq(42)
      end

      it "resolves the record via the sibling id's VALUE-LEVEL default when the write chain is refused" do
        # The parent value is an opaque object: extraction of both :company and :company_id reads absent,
        # the defaults write pass refuses (non-Hash parent), and ONLY the sibling id subfield's own
        # value-level default (its reader applies default: 42) can supply the lookup token.
        opaque = Class.new.new
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload # untyped
          expects :company_id, on: :thing, type: Integer, default: 42
          expects :company, on: :thing, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, optional: true, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        result = action.call(payload: { thing: opaque })
        expect(result).to be_ok
        expect(result.cid).to eq(42)
      end

      it "does NOT override a present raw id with the sibling default (a failed lookup stays nil)" do
        # The wire carries company_id: 7; the finder returns nil for 7 (only 42 resolves). The present raw
        # id must resolve the record directly — the sibling default never overrides it, so :company stays
        # nil rather than silently falling back to id 42.
        finder_class = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.fetch(id) = id == 42 ? new(id) : nil
        end
        stub_const("PickyCompany", finder_class)
        action = build_axn do
          expects :payload, type: Hash
          expects :company_id, on: :payload, type: Integer, default: 42
          expects :company, on: :payload, model: { klass: PickyCompany, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        expect(action.call(payload: { company_id: 7 }).cid).to be_nil
      end
    end

    context "with a transformed sibling <field>_id feeding a STRICT finder (present id, PRO-2910)" do
      # A finder that resolves ONLY the exactly-transformed token — so the RAW wire id misses. The
      # record lookup must consume the same transformed id the `<field>_id` reader/validation see, not
      # the raw token (the PR #173 subfield finding).
      let(:strict_class) do
        Class.new do
          def self.registry = @registry ||= {}
          attr_reader :id

          def initialize(id) = @id = id
          def self.fetch(id) = registry[id]
        end
      end

      before { stub_const("StrictCo", strict_class) }

      it "resolves the record from a coerced sibling id (string wire value → integer finder key)" do
        strict_class.registry[5] = strict_class.new(5)
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, coerce: Integer # wire sends "5"
          expects :company, on: :meta, model: { klass: StrictCo, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta: { company_id: "5" })

        expect(result).to be_ok
        expect(result.cid).to eq(5) # finder consumed the COERCED 5, not the raw "5"
      end

      it "resolves the record from a preprocessed sibling id" do
        strict_class.registry["5"] = strict_class.new("5")
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, preprocess: lambda(&:strip)
          expects :company, on: :meta, model: { klass: StrictCo, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta: { company_id: " 5 " })

        expect(result).to be_ok
        expect(result.cid).to eq("5")
      end

      it "resolves via a coerced sibling id under coerce_input_types (no per-field coerce:)" do
        strict_class.registry[5] = strict_class.new(5)
        action = build_axn do
          configure { |c| c.coerce_input_types = true }
          expects :meta, type: Hash
          expects :company_id, on: :meta, type: Integer
          expects :company, on: :meta, model: { klass: StrictCo, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta: { company_id: "5" })

        expect(result).to be_ok
        expect(result.cid).to eq(5)
      end

      it "prefers the id route declared BESIDE the model over a differently-transformed merged route" do
        # A merged `company_id` node with two routes onto the same wire key: an earlier dotted route with
        # NO coercion, and the route declared next to the model (on: :thing) that coerces to Integer.
        # The finder must retry with the id from the model's OWN route (coerced 5), not declaration-order
        # first (raw "5", which the strict finder misses).
        strict_class.registry[5] = strict_class.new(5)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload # untyped
          expects :company_id, on: "payload.thing", as: :pt_company_id            # route A: raw, first
          expects :company_id, on: :thing, coerce: Integer, as: :thing_company_id # route B: beside model
          expects :company, on: :thing, model: { klass: StrictCo, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: { company_id: "5" } })

        expect(result).to be_ok
        expect(result.cid).to eq(5) # route B coerced "5" → 5; route A's raw "5" would have missed
      end

      it "resolves nil when a present sibling id's preprocess maps it to nil (tolerant finder, never raw)" do
        # A TOLERANT finder would resolve the raw token; the model must instead agree with the `company_id`
        # reader, which preprocesses the present value to nil — so no record is looked up.
        tolerant = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("TolerantCo", tolerant)
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, optional: true, preprocess: ->(v) { v == "none" ? nil : v }
          expects :company, on: :meta, model: { klass: TolerantCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta: { company_id: "none" })

        expect(result).to be_ok
        expect(result.cid).to be_nil
      end

      it "does not fall through to another merged route when the own route maps a PRESENT id to nil" do
        # Merged company_id node: the own route (on: :thing) preprocesses a present "none" to nil with NO
        # default; a DIFFERENT route (dotted) carries a usable default 42. The own route is the model's
        # canonical id (its reader is nil here), so the model must resolve nil — never fall through to the
        # other route (which would re-read the shared wire value / its default). The credited default route
        # rescues only an ABSENT id, not a present one the own route nils out.
        tolerant = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("MergedNilCo", tolerant)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload # untyped
          expects :company_id, on: "payload.thing", optional: true, default: 42, as: :pt_company_id # other route: default
          expects :company_id, on: :thing, optional: true, preprocess: ->(v) { v == "none" ? nil : v }, as: :t_company_id # own route
          expects :company, on: :thing, model: { klass: MergedNilCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          exposes :own_reader, allow_nil: true
          def call = expose(cid: company&.id, own_reader: t_company_id)
        end

        result = action.call(payload: { thing: { company_id: "none" } })

        expect(result).to be_ok
        expect(result.own_reader).to be_nil # the own route resolves the present "none" to nil
        expect(result.cid).to be_nil        # the model agrees with the own route, not the other route's 42
      end

      it "still rescues an ABSENT merged id via a different route's credited default" do
        # Same merged shape, but the id is OMITTED entirely: now the credited default route (42) legitimately
        # rescues (the PRO-2889 omitted-id rescue), because the own route's nil is absence, not a nilled value.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("MergedAbsentCo", finder)
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, allow_blank: true
          expects :company_id, on: "payload.thing", optional: true, default: 42, as: :pt_company_id
          expects :company_id, on: :thing, optional: true, preprocess: ->(v) { v == "none" ? nil : v }, as: :t_company_id
          expects :company, on: :thing, model: { klass: MergedAbsentCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(payload: { thing: {} }) # id omitted entirely (parent present, id absent)

        expect(result).to be_ok
        expect(result.cid).to eq(42) # the credited default route rescues the absent id
      end
    end

    context "with a model subfield reached via a dotted on: and a sibling id (PRO-2889)" do
      # `expects :company, on: "payload.meta", model: ...` and `expects :company_id, on: "payload.meta", ...`
      # are siblings under the `payload.meta` wire node, so sibling lookups key off that shared wire parent.
      let(:r4_class) do
        Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def name = "Acme"
          def self.fetch(id) = new(id)
          def self.find(id) = new(id)
        end
      end

      before { stub_const("R4Co", r4_class) }

      it "resolves the record via the sibling id's VALUE-LEVEL default when the write chain is refused (C7)" do
        opaque = Class.new.new
        action = build_axn do
          expects :payload, type: Hash
          expects :company_id, on: "payload.meta", optional: true, default: 42
          expects :company, on: "payload.meta", model: { klass: R4Co, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        result = action.call(payload: { meta: opaque })
        expect(result).to be_ok
        expect(result.cid).to eq(42)
      end

      it "resolves via the wire write-back when the object-shaped chain omits the id (regression)" do
        action = build_axn do
          expects :payload, type: Hash
          expects :company_id, on: "payload.meta", optional: true, default: 42
          expects :company, on: "payload.meta", model: { klass: R4Co, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        # The chain is present but omits the id; the sibling `<field>_id` default supplies the lookup
        # token on the read path (a blank `payload: {}` would now fail the parent's own presence).
        expect(action.call(payload: { meta: {} }).cid).to eq(42)
      end

      it "skips the id default when the sibling record is already present (C8)" do
        action = build_axn do
          expects :payload, type: Hash
          expects :company_id, on: "payload.meta", optional: true, default: 42
          expects :company, on: "payload.meta", model: { klass: R4Co, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        result = action.call(payload: { meta: { company: R4Co.new(7) } })
        expect(result).to be_ok
        expect(result.cid).to eq(7)
      end

      it "loads cleanly: the sibling id credits the required descendant's rescue (declaration side)" do
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :company_id, on: "payload.meta", optional: true, default: 42
            expects :company, on: "payload.meta", model: { klass: R4Co, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String
            def call = nil
          end
        end.not_to raise_error
      end
    end

    context "resolve_value cache is scoped to the settled pipeline (PRO-2889)" do
      it "reads the settled wire value, not a value cached before preprocess/defaults settled" do
        # An earlier field's preprocess touches the `company` reader, which (via
        # resolve_model_via_sibling_id) resolves the sibling `company_id` through
        # resolve_value BEFORE its own preprocess/default have run — caching the pre-pipeline default
        # (42). Validation must read the SETTLED wire value (preprocess wrote 6), not the stale cache.
        action = build_axn do
          # kick's preprocess touches the `company` reader early (before the pipeline settles).
          expects :kick, type: String, preprocess: lambda { |v|
            company
            v
          }
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: "payload.meta", type: Integer, default: 42,
                               preprocess: ->(v) { (v || 5) + 1 }, inclusion: { in: [6] }
          expects :company, on: :meta, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          def call = nil
        end
        expect(action.call(kick: "go", payload: { meta: {} })).to be_ok
      end
    end

    context "a merged nil-tolerant non-model route at a sibling-id-rescued node (PRO-2889)" do
      it "runs after loading cleanly: the model route resolves via the sibling id, non-model nil tolerated" do
        probe = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def name = "answered"
          def self.fetch(id) = new(id)
        end
        stub_const("ProbeCo", probe)
        # Two routes converge on the payload.meta.company wire node: the `:company` model route (on: :meta)
        # and a nil-tolerant non-model route reaching the same node via a distinct `on:` (aliased so the
        # readers don't collide). The model route resolves via the sibling id; the non-model route tolerates nil.
        action = build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: ProbeCo, finder: :fetch }, allow_nil: true
          expects :company, on: "payload.meta", type: ProbeCo, optional: true, as: :company_alt
          expects :name, on: :company, type: String, method_call: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        # The chain is present but omits the id; the sibling `<field>_id` default supplies the lookup
        # token on the read path (a blank `payload: {}` would now fail the parent's own presence).
        expect(action.call(payload: { meta: {} }).cid).to eq(42)
      end
    end

    context "a leaf default must not clobber a model-routed wire key (PRO-2889)" do
      it "resolves the record via the sibling id, not the non-model route's written default" do
        # A non-model route (untyped, optional, default {x:1}) shares the payload.meta.company wire node
        # with the `:company` model route via a distinct `on:` (aliased). Nothing is written back on the
        # read path, so the non-model route's default never lands on the shared key to be misread AS the
        # record: the model route resolves via the sibling id 42, and the non-model route's default
        # resolves value-level for its own reader.
        action = build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
          expects :company, on: "payload.meta", optional: true, default: { x: 1 }, as: :company_alt
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        result = action.call(payload: { meta: {} })
        expect(result).to be_ok
        expect(result.cid).to eq(42)
      end
    end

    context "an id-sibling default must not manufacture a model-consistency mismatch (PRO-2889)" do
      it "honors a present sibling record over axn's own id default" do
        finder_class = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("FindCo", finder_class)
        action = build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: FindCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        result = action.call(payload: { meta: { company: FindCo.new(7) } })
        expect(result).to be_ok
        expect(result.cid).to eq(7)
      end

      it "still supplies the id default as a lookup token when the record is absent" do
        finder_class = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("FindCo", finder_class)
        action = build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :company_id, on: :meta, type: Integer, default: 42
          expects :company, on: :meta, model: { klass: FindCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        # The chain is present but omits the id; the sibling `<field>_id` default supplies the lookup
        # token on the read path (a blank `payload: {}` would now fail the parent's own presence).
        expect(action.call(payload: { meta: {} }).cid).to eq(42)
      end
    end

    context "subfield model-consistency compares against the TRANSFORMED sibling id (PRO-2910)" do
      # The subfield consistency check must compare a present record against the id the reader/finder
      # actually see (its coerce:/preprocess: applied), not the raw token — mirroring top-level.
      let(:find_class) do
        Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
      end

      before { stub_const("ConsistCo", find_class) }

      it "does NOT fabricate a conflict when a present record matches the id only after preprocess:" do
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, preprocess: lambda(&:strip)
          expects :company, on: :meta, model: { klass: ConsistCo, finder: :find }, allow_nil: true
          def call = nil
        end

        result = action.call(meta: { company: ConsistCo.new("5"), company_id: " 5 " })

        expect(result).to be_ok # raw " 5 " != record id "5", but the stripped "5" matches
      end

      it "still raises when the present record disagrees with the transformed id" do
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, preprocess: lambda(&:strip)
          expects :company, on: :meta, model: { klass: ConsistCo, finder: :find }, allow_nil: true
          def call = nil
        end

        result = action.call(meta: { company: ConsistCo.new("5"), company_id: " 6 " })

        expect(result).not_to be_ok
        expect(result.exception.message).to match(/conflicts with company_id="6"/)
      end

      it "compares against the model's OWN-route id in a merged node (not declaration-order first)" do
        # Merged `company_id` node: route A (dotted) raw and declared first, route B (on: :thing) strips —
        # declared beside the model. The consistency check must compare the present record against route B's
        # transformed id (matching the finder path), not route A's raw value.
        action = build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload # untyped
          expects :company_id, on: "payload.thing", as: :pt_company_id # route A: raw, first
          expects :company_id, on: :thing, preprocess: lambda(&:strip), as: :t_company_id # route B: beside model
          expects :company, on: :thing, model: { klass: ConsistCo, finder: :find }, allow_nil: true
          def call = nil
        end

        result = action.call(payload: { thing: { company: ConsistCo.new("5"), company_id: " 5 " } })

        expect(result).to be_ok # route B strips " 5 " → "5" == record id "5"; route A's raw " 5 " would conflict
      end
    end

    context "a model whose sibling <field>_id opts into method_call: on a PORO/Data parent (PRO-2910)" do
      # The SIBLING `<field>_id` declaration governs how the id KEY is read; the model config governs how
      # the RECORD is read. When the id opts into method dispatch but the model does not, the id-key
      # presence probe (used by both the finder path and the consistency check) must honor the sibling id
      # route's method_call — otherwise it raises MethodCallNotPermittedError before the sibling reader
      # (which does permit the dispatch and transform) is ever consulted.
      let(:strict_class) do
        Class.new do
          def self.registry = @registry ||= {}
          attr_reader :id

          def initialize(id) = @id = id
          def self.fetch(id) = registry[id]
          def self.find(id) = registry[id]
        end
      end

      before { stub_const("McCo", strict_class) }

      it "resolves the record via the method_call sibling id (finder path)" do
        strict_class.registry[5] = strict_class.new(5)
        # A PORO parent: `company_id` is a METHOD (needs dispatch); no `company` reader (record absent).
        meta = Class.new { def company_id = "5" }.new
        action = build_axn do
          expects :meta
          expects :company_id, on: :meta, method_call: true, coerce: Integer # wire method returns "5"
          expects :company, on: :meta, model: { klass: McCo, finder: :fetch }, allow_nil: true # NO method_call:
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta:)

        expect(result).to be_ok
        expect(result.cid).to eq(5) # sibling id read via dispatch, coerced "5" → 5, fetched
      end

      it "compares a present record against the method_call sibling id (consistency path)" do
        # A Data parent: `company` is a declared MEMBER (safe read → record present, no method_call needed),
        # while `company_id` is a behavioral METHOD (needs dispatch). The consistency check's id-key probe
        # must honor the sibling id's method_call even though the model config has none.
        record = strict_class.new("5")
        parent_class = Data.define(:company) do
          def company_id = " 5 "
        end
        action = build_axn do
          expects :meta
          expects :company_id, on: :meta, method_call: true, preprocess: lambda(&:strip)
          expects :company, on: :meta, model: { klass: McCo, finder: :find }, allow_nil: true # NO method_call:
          def call = nil
        end

        result = action.call(meta: parent_class.new(company: record))

        expect(result).to be_ok # stripped " 5 " → "5" == record id "5"; no false conflict, no method-call raise
      end

      it "dispatches a method_call sibling id reader at most once (finder + reader share one read)" do
        # A NON-idempotent method reader: `company_id` returns "5" once, then nil. The finder's presence probe
        # and the id reader must consume the SAME dispatch — a second invocation would read nil and make the
        # lookup miss even though the reader resolves to 5.
        strict_class.registry[5] = strict_class.new(5)
        meta = Class.new do
          def initialize = @calls = 0

          def company_id
            @calls += 1
            @calls == 1 ? "5" : nil
          end
        end.new
        action = build_axn do
          expects :meta
          expects :company_id, on: :meta, method_call: true, coerce: Integer
          expects :company, on: :meta, model: { klass: McCo, finder: :fetch }, allow_nil: true # NO method_call:
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta:)

        expect(result).to be_ok
        expect(result.cid).to eq(5) # method dispatched once; a second dispatch (nil) would miss
      end

      it "reads a method_call RECORD key at most once when deriving from the implicit id (no declared id)" do
        # No declared `<field>_id`, `method_call: true` model, PORO parent exposing BOTH `company` and
        # `company_id`. The record key is read once (present_record); the finder must derive from the id
        # ALONE (never re-read the record key) and the consistency check must reuse that one read. A one-shot
        # `company` (nil, then a spurious record) would otherwise resolve the model from the wrong value.
        strict_class.registry[5] = strict_class.new(5)
        spurious = Struct.new(:id).new(999)
        meta = Class.new do
          define_method(:initialize) { @calls = 0 }
          define_method(:company) do
            @calls += 1
            @calls == 1 ? nil : spurious
          end
          def company_id = 5
        end.new
        action = build_axn do
          expects :meta
          expects :company, on: :meta, method_call: true, model: { klass: McCo, finder: :find }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end

        result = action.call(meta:)

        expect(result).to be_ok # no spurious record → no false record-vs-id conflict
        expect(result.cid).to eq(5) # derived from the implicit id 5, not the re-read spurious record
      end
    end

    context "a stateful sibling <field>_id transform runs at most once (model declared BEFORE its id, PRO-2910)" do
      # When the model is declared before its (aliased) `<field>_id`, inbound validation resolves the model
      # first, so the finder reads the sibling id reader WHILE the model is mid-resolution. That read must
      # still CACHE (the id's parent is already settled — a model LOOKUP is not a parent transform), so the
      # id's own later validation read reuses it instead of re-running the transform. Otherwise a stateful/
      # non-idempotent preprocess: runs twice and the record's id disagrees with what the reader exposes.
      it "resolves the record and the reader from a SINGLE preprocess run (they agree)" do
        runs = []
        finder = Class.new do
          def self.seen = @seen ||= []
          attr_reader :id

          def initialize(id) = @id = id

          def self.find(id)
            seen << id
            new(id)
          end
        end
        stub_const("OnceCo", finder)
        # A stateful preprocess: a different token on each call — so a second run would make the record's id
        # (from the finder) and the `<field>_id` reader disagree.
        stateful = lambda do |_v|
          runs << :call
          "id#{runs.size}"
        end
        action = build_axn do
          expects :meta, type: Hash
          expects :company, on: :meta, model: { klass: OnceCo, finder: :find }, allow_nil: true # declared FIRST
          expects :company_id, on: :meta, as: :the_cid, preprocess: stateful
          exposes :record_id, :reader_id, allow_nil: true
          def call = expose(record_id: company&.id, reader_id: the_cid)
        end

        result = action.call(meta: { company_id: "raw" })

        expect(result).to be_ok
        expect(runs.size).to eq(1)                       # preprocess ran once, not twice
        expect(result.record_id).to eq(result.reader_id) # record's id agrees with the reader
        expect(finder.seen).to eq(["id1"])               # finder consumed the one transformed token
      end
    end

    context "the auto <field>_id companion agrees with the transformed lookup when the id is aliased (PRO-2910)" do
      # An `as:`-aliased sibling `<field>_id` frees the `<field>_id` name, so the model still generates its
      # own `<field>_id` companion reader. That companion must yield the SAME declared/transformed token the
      # record lookup consumed (mirroring the top-level companion), not the raw wire value — otherwise the
      # record and the auto companion expose inconsistent ids.
      it "returns the transformed id from the subfield companion, matching the resolved record" do
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = new(id)
        end
        stub_const("AliasCo", finder)
        action = build_axn do
          expects :meta, type: Hash
          expects :company_id, on: :meta, as: :stripped_id, preprocess: lambda(&:strip)
          expects :company, on: :meta, model: { klass: AliasCo, finder: :find }, allow_nil: true
          exposes :record_id, :companion_id, :aliased_id, allow_nil: true
          def call = expose(record_id: company&.id, companion_id: company_id, aliased_id: stripped_id)
        end

        result = action.call(meta: { company_id: " 5 " })

        expect(result).to be_ok
        expect(result.record_id).to eq("5") # lookup consumed the stripped token
        expect(result.companion_id).to eq("5") # auto companion agrees (not the raw " 5 ")
        expect(result.aliased_id).to eq("5")   # and matches the explicit aliased reader
      end
    end

    context "subfield reader memos are cleared at the pipeline boundary (PRO-2889)" do
      it "validates the settled parent value, not a value memoized before the parent was rewritten" do
        # payload's preprocess reads the `name` subfield reader (== "ok"), memoizing it, BEFORE returning
        # a rewritten parent ({name: 123}). Without clearing the generated reader's memo at the boundary,
        # validation public_sends `name` and sees the stale pre-rewrite "ok" — invalid input passes.
        action = build_axn do
          expects :payload, type: Hash, preprocess: lambda { |_v|
            name
            { name: 123 }
          }
          expects :name, on: :payload, type: String
          def call = nil
        end
        result = action.call(payload: { name: "ok" })
        expect(result).not_to be_ok
        expect(result.exception.message).to match(/Name is not a String/)
      end

      it "re-resolves a model subfield record against the rewritten parent id" do
        # payload's preprocess reads the `company` model reader (resolving id 1's record), memoizing it,
        # BEFORE returning a rewritten parent carrying company_id: 2. Without the boundary clear the
        # memoized record (id 1) survives and the run exposes the stale record.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def self.fetch(id) = new(id)
        end
        stub_const("MemoCo", finder)
        action = build_axn do
          expects :payload, type: Hash, preprocess: lambda { |_v|
            company
            { company_id: 2 }
          }
          expects :company, on: :payload, model: { klass: MemoCo, finder: :fetch }, allow_nil: true
          exposes :cid, allow_nil: true
          def call = expose(cid: company&.id)
        end
        expect(action.call(payload: { company_id: 1 }).cid).to eq(2)
      end

      it "clears the raw-extract memo, so a PRE-pipeline read doesn't pin a stale subfield wire value (PRO-2910)" do
        # A dynamic `sensitive:` predicate resolved during before-logging (auto_log) reads the `leaf` subfield
        # reader BEFORE validation — a pre-pipeline read. With a stateful parent preprocess the settled parent
        # differs from the pre-pipeline one, so the child must re-resolve against the settled parent. The
        # raw-extract memo (keyed by config in resolve_value) has to be dropped at the pipeline boundary
        # alongside the value cache / reader memos; otherwise the body reads the stale pre-pipeline leaf.
        runs = { n: 0 }
        stateful_parent = lambda do |_v|
          runs[:n] += 1
          { leaf: "run#{runs[:n]}" }
        end
        action = build_axn do
          auto_log :info
          expects :payload, type: Hash, preprocess: stateful_parent
          expects :leaf, on: :payload, type: String
          expects :trigger, sensitive: -> { leaf == "peek" } # predicate reads `leaf` → pre-pipeline read
          exposes :seen_leaf, allow_nil: true
          def call = expose(seen_leaf: leaf)
        end

        result = action.call(payload: { leaf: "orig" }, trigger: "t")

        expect(result).to be_ok
        expect(result.seen_leaf).to eq("run2") # the SETTLED preprocess value, not the stale pre-pipeline "run1"
      end
    end

    context "two defaults on one sibling-id wire node are rejected at declaration (PRO-2901)" do
      it "rejects the blank-token + usable-token routes that shared the thing.company_id wire node" do
        # Two routes land on the same payload.thing.company_id wire node via distinct `on:` (aliased so
        # their readers don't collide with each other or the model's `company_id` companion): a
        # blank-token route (default "") and a usable-token route (default 42). PRO-2889's read-side
        # selection made the RUNTIME survive this by resolving the usable route — but two explicit
        # defaults for one wire value have no principled winner, so PRO-2901 rejects the construction at
        # declaration rather than papering over the write-order interaction. The error names both routes.
        finder = Class.new do
          attr_reader :id

          def initialize(id) = @id = id
          def name = "acme"
          def self.fetch(id) = new(id)
        end
        stub_const("SiblingCo", finder)
        expect do
          build_axn do
            expects :payload, type: Hash
            expects :thing, on: :payload # untyped, so an opaque parent refuses the write-back
            expects :company_id, on: "payload.thing", optional: true, default: "", as: :pt_company_id
            expects :company_id, on: :thing, type: Integer, default: 42, as: :thing_company_id
            expects :company, on: :thing, model: { klass: SiblingCo, finder: :fetch }, allow_nil: true
            expects :name, on: :company, type: String, method_call: true
            exposes :cid, allow_nil: true
            def call = expose(cid: company&.id)
          end
        end.to raise_error(ArgumentError, /conflicting default:.*payload\.thing\.company_id/m)
      end
    end

    context "a descendant anchored on an aliased merged route resolves through THAT route (PRO-2926)" do
      it "reads the leaf through the anchoring route's reader, honoring its default" do
        # foo.bar.baz is a merged node: route1 (reader :baz) and route2 (reader :bar_baz, with a default).
        # A descendant anchored `on: :bar_baz` must resolve its parent through route2's reader — seeing
        # route2's default — not through the first-declared route's reader (which would read a different value).
        action = build_axn do
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash, optional: true, allow_nil: true
          expects :baz, on: "foo.bar", type: Hash, optional: true, allow_nil: true
          expects :baz, on: :bar, as: :bar_baz, type: Hash, optional: true, default: { note: "route2" }
          expects :note, on: :bar_baz, optional: true, allow_nil: true
          exposes :via_note, allow_nil: true
          def call = expose(via_note: note)
        end
        # `bar` absent: route1 `:baz` resolves nil; route2 `:bar_baz` resolves its default {note: "route2"}.
        expect(action.call(foo: { other: 1 }).via_note).to eq("route2")
      end
    end
  end
end
