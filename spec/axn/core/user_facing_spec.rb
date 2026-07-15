# frozen_string_literal: true

RSpec.describe "expects ..., user_facing:" do
  describe "a required user_facing field, omitted" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        expects :note, user_facing: true

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
    end

    it "settles as a failure, not an exception" do
      expect(action.call.outcome).to be_failure
    end

    it "fires on_failure but not on_exception" do
      action.call
      expect(fired).to contain_exactly(:failure)
    end

    it "surfaces the field's validation message on result.error" do
      expect(action.call.error).to eq("Note can't be blank")
    end

    it "preserves the structured InboundValidationError on result.exception" do
      expect(action.call.exception).to be_a(Axn::InboundValidationError)
    end

    it "reports the failure outcome to an on_error observer (which fires before the context flag is set)" do
      observed = []
      recorder = observed
      action = build_axn do
        expects :note, user_facing: true
        on_error { recorder << result.outcome.to_s }
        def call = nil
      end
      action.call
      expect(observed).to eq(["failure"])
    end
  end

  describe "string field names" do
    it "reclassifies a string-declared field, matching the symbolized failing attribute" do
      # ActiveModel reports the failing attribute as :note, but `expects "note"` stores config.field
      # as the string "note" — the user_facing opt-in must be normalized to the same key or the
      # reclassification misses and the field wrongly stays in the exception bucket.
      action = build_axn do
        expects "note", user_facing: true
        def call = nil
      end
      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Note can't be blank")
    end
  end

  describe "the field stays required (unlike optional: true)" do
    let(:action) do
      build_axn do
        expects :note, user_facing: true
        def call = nil
      end
    end

    it "succeeds when the value is present" do
      expect(action.call(note: "hello").outcome).to be_success
    end

    it "fails (presence still enforced) when blank" do
      expect(action.call(note: "").outcome).to be_failure
    end
  end

  describe "message overrides" do
    it "uses a String value verbatim as the surfaced message" do
      action = build_axn do
        expects :note, user_facing: "Please add a note"
        def call = nil
      end
      expect(action.call.error).to eq("Please add a note")
    end

    it "uses a Proc value, invoked with the InboundValidationError" do
      action = build_axn do
        expects :note, user_facing: ->(e) { "Problem: #{e.message}" }
        def call = nil
      end
      expect(action.call.error).to eq("Problem: Note can't be blank")
    end

    it "uses a Symbol value, naming an action method (arity-filtered like error/fail!)" do
      action = build_axn do
        expects :note, user_facing: :note_message
        def call = nil
        def note_message(e) = "Symbol says: #{e.message}"
      end
      expect(action.call.error).to eq("Symbol says: Note can't be blank")
    end

    it "falls back to the field's own validation message when an override resolves blank" do
      action = build_axn do
        expects :note, user_facing: ->(_e) { "" }
        def call = nil
      end
      # a blank override must never leak the dev-facing generic message on a user-facing failure
      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Note can't be blank")
    end

    it "treats a falsey override (false/nil) as blank, not the literal string" do
      action = build_axn do
        expects :note, user_facing: ->(_e) { false }
        def call = nil
      end
      # false means "no message" — must fall back, never surface "false"
      expect(action.call.error).to eq("Note can't be blank")
    end
  end

  describe "non-presence validations are equally user-facing" do
    let(:action) do
      build_axn do
        expects :age, type: Integer, numericality: { greater_than: 18 }, user_facing: true
        def call = nil
      end
    end

    it "surfaces the failing validation's message" do
      result = action.call(age: 5)
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Age must be greater than 18")
    end
  end

  # The user-facing message is a failure *reason*: a declared base `error` headlines it by default,
  # exactly like a `fail!` reason (see PRO-2746 nested-error-message attachment). Opting a single
  # field out (`standalone: true`) is deliberately deferred.
  describe "prefixing by a declared base error" do
    it "prefixes the field's own message under the base headline" do
      action = build_axn do
        error "Couldn't save widget"
        expects :note, user_facing: true
        def call = nil
      end
      expect(action.call.error).to eq("Couldn't save widget: Note can't be blank")
    end

    it "prefixes a String override too" do
      action = build_axn do
        error "Couldn't save widget"
        expects :note, user_facing: "Add a note"
        def call = nil
      end
      expect(action.call.error).to eq("Couldn't save widget: Add a note")
    end

    it "honors the base's custom join" do
      action = build_axn do
        error "Couldn't save widget", join: " — "
        expects :note, user_facing: true
        def call = nil
      end
      expect(action.call.error).to eq("Couldn't save widget — Note can't be blank")
    end

    it "stands alone when no base error is declared" do
      action = build_axn do
        expects :note, user_facing: true
        def call = nil
      end
      expect(action.call.error).to eq("Note can't be blank")
    end

    it "matches fail! parity (same base prefixes a fail! reason identically)" do
      action = build_axn do
        error "Couldn't save widget"
        def call = fail!("Add a note")
      end
      expect(action.call.error).to eq("Couldn't save widget: Add a note")
    end
  end

  describe "multiple user_facing fields failing together" do
    it "combines their messages via to_sentence" do
      action = build_axn do
        expects :note, user_facing: true
        expects :title, user_facing: true
        def call = nil
      end
      expect(action.call.error).to eq("Note can't be blank and Title can't be blank")
    end

    it "scopes each field's handler to its own error (a shared e.message doesn't cross-contaminate)" do
      action = build_axn do
        expects :note, user_facing: ->(e) { "Bad: #{e.message}" }
        expects :title, user_facing: ->(e) { "Bad: #{e.message}" }
        def call = nil
      end
      # each handler sees only its own field's error — were the aggregate passed, every part would
      # read "Bad: Note can't be blank and Title can't be blank"
      expect(action.call.error).to eq("Bad: Note can't be blank and Bad: Title can't be blank")
    end
  end

  describe "user_facing: on a shape member" do
    it "surfaces the member's own message when the member opts in with true" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: true
        end
        def call = nil
      end
      result = action.call(items: [{ status: "bogus" }])
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Items element at index 0: status is not included in the list")
    end

    it "surfaces a String override" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: "Each item needs a valid status"
        end
        def call = nil
      end
      result = action.call(items: [{ status: "bogus" }])
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Each item needs a valid status")
    end

    it "invokes a Symbol handler on the action" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: :status_msg
        end
        def status_msg = "Pick a real status"
        def call = nil
      end
      expect(action.call(items: [{ status: "bogus" }]).error).to eq("Pick a real status")
    end

    it "computes a Proc handler from the member's own error" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: ->(e) { "Bad: #{e.message}" }
        end
        def call = nil
      end
      expect(action.call(items: [{ status: "bogus" }]).error)
        .to eq("Bad: Items element at index 0: status is not included in the list")
    end

    it "stays dev-facing when the member does not opt in" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }
        end
        def call = nil
      end
      result = action.call(items: [{ status: "bogus" }])
      expect(result.outcome).to be_exception
      expect(result.error).to eq("Something went wrong")
    end

    it "collapses a String override to one clause across multiple failing elements" do
      action = build_axn do
        expects :items, type: Array do
          field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: "Each item needs a valid status"
        end
        def call = nil
      end
      result = action.call(items: [{ status: "a" }, { status: "b" }])
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Each item needs a valid status")
    end

    it "composes a user_facing member nested inside a nested shape" do
      action = build_axn do
        expects :order, type: Hash do
          field :line, type: Hash do
            field :sku, type: String, user_facing: "SKU is required"
          end
        end
        def call = nil
      end
      result = action.call(order: { line: { sku: 123 } })
      expect(result.outcome).to be_failure
      expect(result.error).to eq("SKU is required")
    end

    it "scopes each member's handler to its own error when two siblings fail together" do
      # Both members fold into the SAME parent ContractFailure — the member-specific structural case
      # (a field-level analog can't produce, since distinct fields are distinct configs). Each handler
      # must see only its own member's error: were the aggregate passed, both parts would read "…a…and…b…".
      action = build_axn do
        expects :items, type: Array do
          field :a, type: String, user_facing: ->(e) { "A: #{e.message}" }
          field :b, type: String, user_facing: ->(e) { "B: #{e.message}" }
        end
        def call = nil
      end
      result = action.call(items: [{ a: 1, b: 2 }])
      expect(result.outcome).to be_failure
      expect(result.error).to eq("A: Items element at index 0: a is not a String and B: Items element at index 0: b is not a String")
    end

    it "rejects a non-parity user_facing value on a member at declaration" do
      expect do
        build_axn do
          expects :items, type: Array do
            field :status, type: String, user_facing: 123
          end
        end
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    it "rejects user_facing: on an exposes shape member (outbound failures are always dev-facing)" do
      expect do
        build_axn do
          exposes :items, type: Array do
            field :status, type: String, user_facing: "surfaced"
          end
        end
      end.to raise_error(ArgumentError, /does not support user_facing: on exposes/)
    end

    it "rejects user_facing: on a nested exposes shape member too" do
      expect do
        build_axn do
          exposes :order, type: Hash do
            field :line, type: Hash do
              field :sku, type: String, user_facing: "surfaced"
            end
          end
        end
      end.to raise_error(ArgumentError, /does not support user_facing: on exposes/)
    end
  end

  describe "mixed failure: dev-facing dominates" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        expects :note, user_facing: true
        expects :company_id, type: Integer

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
    end

    it "settles dev-facing when a non-user-facing field also fails" do
      result = action.call # both note and company_id blank
      expect(result.outcome).to be_exception
      expect(fired).to contain_exactly(:exception)
      expect(result.error).to eq("Something went wrong")
    end

    it "settles user-facing when only the user_facing field fails" do
      result = action.call(company_id: 5) # blank note, valid company_id
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Note can't be blank")
    end

    it "settles dev-facing when only the non-user-facing field fails" do
      result = action.call(note: "hi") # company_id blank
      expect(result.outcome).to be_exception
    end
  end

  describe "dev-facing dominance extends to subfield checks" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        expects :payload
        expects :id, on: :payload, type: Integer # dev-facing subfield
        expects :note, user_facing: true

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
    end

    it "stays dev-facing when a dev-facing subfield also fails" do
      # omits the user-facing :note AND sends payload.id of the wrong type (dev-facing subfield)
      result = action.call(payload: { id: "x" })
      expect(result.outcome).to be_exception
      expect(fired).to contain_exactly(:exception)
    end

    it "does not invoke the user_facing handler when a dev-facing check dominates" do
      invoked = []
      recorder = invoked
      action = build_axn do
        expects :note, user_facing: lambda { |_e|
          recorder << :invoked
          "msg"
        }
        expects :payload
        expects :id, on: :payload, type: Integer # independent dev-facing subfield
        def call = nil
      end
      # :note omitted (user-facing) AND payload.id wrong type (independent dev-facing) → exception
      # dominates and discards the user-facing message, so its handler must never run.
      result = action.call(payload: { id: "x" })
      expect(result.outcome).to be_exception
      expect(invoked).to be_empty
    end
  end

  # Subfields and model consistency are *always* dev-facing (`user_facing:` is rejected on a field
  # that has subfields — see the "rejected on a field with subfields" group). So a subfield/model
  # violation is always independent of any user-facing top-level failure, and a real one still pages.
  describe "an independent dev-facing subfield still dominates a user-facing top-level failure" do
    it "pages when a subfield of a separate (non-user-facing) parent can't resolve" do
      # :note is the (blank) user-facing field; :payload is a separate required field that's absent, so
      # both its own presence and its required subfield :id fail. That's an independent dev-facing
      # contract error, so it pages exactly as it would with no user_facing field in play.
      fired = []
      recorder = fired
      action = build_axn do
        expects :note, user_facing: true
        expects :payload
        expects :id, on: :payload, type: Integer

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
      result = action.call # :note blank AND :payload absent
      expect(result.outcome).to be_exception
      expect(fired).to contain_exactly(:exception)
    end

    it "propagates a real error raised by a subfield reader rather than masking it" do
      # :payload is present and unrelated to the blank user-facing :note, but reading payload.id
      # raises a genuine bug. That must surface as a dev-facing exception, not be masked behind the
      # user-facing message.
      raising = Class.new { def id = raise("boom from reader") }.new
      action = build_axn do
        expects :note, user_facing: true
        expects :payload
        expects :id, on: :payload, type: Integer

        def call = nil
      end
      result = action.call(payload: raising) # :note blank (user-facing); payload.id raises
      expect(result.outcome).to be_exception
    end
  end

  describe "user_facing: on subfields and on parents with subfields (kwarg parity)" do
    describe "a user_facing subfield failing under a valid parent" do
      let(:action) do
        build_axn do
          expects :payload, type: Hash
          expects :note, on: :payload, user_facing: true
          def call = nil
        end
      end

      it "settles as a user-facing failure with the subfield's own message" do
        result = action.call(payload: { other: 1 })
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Note can't be blank")
      end

      it "succeeds when the subfield is present" do
        expect(action.call(payload: { note: "hi" }).outcome).to be_success
      end
    end

    it "supports the String/Proc override forms on a subfield" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, type: String, user_facing: "Please add a note"
        expects :size, on: :payload, type: String, optional: true,
                       inclusion: { in: %w[s m l] }, user_facing: ->(e) { "Bad size: #{e.message}" }
        def call = nil
      end

      expect(action.call(payload: { size: "m" }).error).to eq("Please add a note")
      expect(action.call(payload: { note: "n", size: "xl" }).error).to eq("Bad size: Size is not included in the list")
    end

    it "composes top-level and subfield user-facing failures into one message" do
      action = build_axn do
        expects :title, user_facing: true
        expects :payload, type: Hash
        expects :note, on: :payload, user_facing: true
        def call = nil
      end

      result = action.call(payload: { other: 1 })
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Title can't be blank and Note can't be blank")
    end

    it "lets a dev-facing subfield violation dominate a user-facing subfield violation (exception, not failure)" do
      action = build_axn do
        expects :payload, type: Hash
        expects :note, on: :payload, type: String, user_facing: true
        expects :id, on: :payload, type: Integer
        def call = nil
      end

      expect(action.call(payload: { other: 1 }).outcome).to be_exception
    end

    describe "aggregate reporting (collect-then-settle)" do
      it "co-reports multiple dev-facing subfield violations in one exception" do
        action = build_axn do
          expects :payload, type: Hash
          expects :id, on: :payload, type: Integer
          expects :count, on: :payload, type: Integer
          def call = nil
        end

        result = action.call(payload: { id: "x", count: "y" })
        expect(result.outcome).to be_exception
        expect(result.exception.errors.map(&:attribute)).to include(:id, :count)
      end

      it "co-reports a dev-facing top-level violation with an independent subfield violation" do
        action = build_axn do
          expects :title
          expects :payload, type: Hash
          expects :id, on: :payload, type: Integer
          def call = nil
        end

        result = action.call(payload: { id: "x" })
        expect(result.outcome).to be_exception
        expect(result.exception.errors.map(&:attribute)).to include(:title, :id)
      end

      it "co-reports a model-consistency mismatch alongside a subfield violation" do
        model = Class.new do
          def self.find(id) = Struct.new(:id).new(id)
          def self.name = "FakeAggModel"
        end

        action = build_axn do
          expects :payload, type: Hash
          expects :id, on: :payload, type: Integer
          expects :company, model: { klass: model }, optional: true
          def call = nil
        end

        result = action.call(payload: { id: "x" }, company: Struct.new(:id).new(1), company_id: 2)
        expect(result.outcome).to be_exception
        expect(result.exception.errors.map(&:attribute)).to include(:id, :base)
        expect(result.exception.message).to include("conflicts with")
      end

      it "prunes a stranded descendant even when it was declared (and validated) before its failing ancestor" do
        # The dotted-path config attaches to an implicit node that a LATER explicit declaration then
        # claims — post-hoc suppression with complete failure knowledge still attributes the stranded
        # deep check to the ancestor, regardless of declaration order.
        action = build_axn do
          expects :payload, type: Hash
          expects :city, on: "payload.address", type: String
          expects :address, on: :payload, type: Hash, user_facing: "Please provide your address"
          def call = nil
        end

        result = action.call(payload: { other: 1 })
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Please provide your address")
      end
    end

    describe "a user_facing parent with subfields (causal suppression)" do
      let(:action) do
        build_axn do
          expects :payload, type: Hash, user_facing: "Payload is missing"
          expects :id, on: :payload, type: Integer
          def call = nil
        end
      end

      it "suppresses the stranded dev-facing subfield check when the parent itself fails (user-facing wins)" do
        result = action.call
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Payload is missing")
      end

      it "still pages on a genuine subfield violation when the parent is present" do
        expect(action.call(payload: { id: "not-an-int" }).outcome).to be_exception
      end

      it "succeeds when both levels are satisfied" do
        expect(action.call(payload: { id: 1 }).outcome).to be_success
      end
    end

    it "suppresses a nested subfield's check when its user_facing SUBFIELD ancestor fails" do
      action = build_axn do
        expects :payload, type: Hash
        expects :settings, on: :payload, type: Hash, user_facing: "Settings are required"
        expects :volume, on: :settings, type: Integer
        def call = nil
      end

      result = action.call(payload: { other: 1 })
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Settings are required")
    end

    it "suppresses a subfield model-consistency check under a failed user-facing parent" do
      model = Class.new do
        def self.find(id) = Struct.new(:id).new(id)
        def self.name = "FakeConsistencyModel"
      end

      action = build_axn do
        expects :payload, type: Hash, user_facing: "Payload is missing"
        expects :company, on: :payload, model: { klass: model }, optional: true
        def call = nil
      end

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Payload is missing")
    end

    it "rejects user_facing: on an ambient_context subfield (framework-supplied, no user to face)" do
      expect do
        build_axn { expects :request_id, on: :ambient_context, user_facing: true }
      end.to raise_error(ArgumentError, /not supported for an ambient_context subfield/)
    end

    describe "user_facing: on a field that also carries a shape block" do
      it "surfaces the field's own failure user-facing" do
        action = build_axn do
          expects :order, type: Hash, user_facing: "Order details are required" do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call # :order omitted → the field's OWN presence fails
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Order details are required")
      end

      it "keeps a member failure dev-facing (does not leak) when the member fails alone" do
        action = build_axn do
          expects :order, type: Hash, user_facing: "Order details are required" do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call(order: { sku: 123 }) # field's own presence OK; member :sku invalid
        expect(result.outcome).to be_exception
        expect(result.error).to eq("Something went wrong")
      end

      it "lets dev-facing dominate and reports BOTH when the field's own check and a member both fail" do
        action = build_axn do
          # A custom `validate:` gives the field its OWN check that fails while the value is still a
          # valid Hash whose member also fails — the only way to co-fail the field's own error and a
          # member error in one call (an absent/wrong-type value would short-circuit ShapeValidator).
          expects :order, type: Hash, user_facing: "Order details are required",
                          validate: ->(v) { "order is not ready" unless v[:ready] } do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call(order: { sku: 123 }) # own validate: fails AND member :sku is not a String
        expect(result.outcome).to be_exception
        expect(result.error).to eq("Something went wrong")
        messages = result.exception.errors.full_messages.join(" ")
        expect(messages).to include("order is not ready")
        expect(messages).to include("sku")
      end

      it "accepts a shape passed as a raw shape: kwarg on a user_facing field" do
        # A raw shape: kwarg carries its own :container (the block form's _build_shape supplies it
        # automatically; a container-less raw shape is malformed independently of user_facing).
        expect do
          build_axn do
            expects :order, type: Hash, user_facing: true, shape: { members: [], container: Hash }
            def call = nil
          end
        end.not_to raise_error
      end
    end

    it "suppresses through an aliased user_facing parent (wire-key identification)" do
      action = build_axn do
        expects :payload, type: Hash, as: :raw_payload, user_facing: "Payload is missing"
        expects :id, on: :raw_payload, type: Integer
        def call = nil
      end

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Payload is missing")
    end

    it "suppresses a dotted on: path rooted at a failed user_facing parent" do
      action = build_axn do
        expects :payload, type: Hash, user_facing: "Payload is missing"
        expects :id, on: "payload.meta", type: Integer
        def call = nil
      end

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("Payload is missing")
    end

    it "still allows subfields on a non-user-facing parent alongside a user_facing top-level field" do
      action = build_axn do
        expects :note, user_facing: true
        expects :payload, type: Hash
        expects :id, on: :payload, type: Integer
        def call = nil
      end
      expect(action.call(note: "hi", payload: { id: 1 }).outcome).to be_success
    end
  end

  describe "declaration-time validation" do
    it "rejects a non-true/String/Symbol/Proc value" do
      expect do
        build_axn { expects(:note, user_facing: 5) }
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    it "rejects a callable object that the handler invoker can't actually invoke (no #arity)" do
      uninvokable = Class.new { def call(_e) = "x" }.new
      expect do
        build_axn { expects(:note, user_facing: uninvokable) }
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    it "rejects an object with #arity but no #to_proc (the invoker calls it via &block)" do
      # The invoker runs callables as `instance_exec(..., &callable)`, which needs `to_proc`. An
      # object answering #arity but not convertible to a block would pass an arity-only check yet
      # raise (and get swallowed) at call time — so reject it at declaration.
      arity_only = Class.new { def arity = 1 }.new
      expect do
        build_axn { expects(:note, user_facing: arity_only) }
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    it "still validates the user_facing: value form for a subfield declaration" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects(:id, on: :payload, user_facing: 5)
        end
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end
  end
end
