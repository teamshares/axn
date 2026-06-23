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
  # exactly like a `fail!` reason (see PRO-2746 nested-error-message prefixing). Opting a single
  # field out (`prefixed: false`) is deliberately deferred.
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

    it "honors the base's custom delimiter" do
      action = build_axn do
        error "Couldn't save widget", delimiter: " — "
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

  describe "a failed user_facing parent doesn't get masked by its own subfield checks" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        expects :payload, type: Hash, user_facing: true
        expects :id, on: :payload # dev-facing subfield hanging off the user_facing parent

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
    end

    it "surfaces the parent's user-facing message rather than a derived subfield blowup" do
      # :payload omitted — its subfield :id can't resolve against the missing parent, but that
      # derived failure must not dominate the parent's own user-facing violation.
      result = action.call
      expect(result.outcome).to be_failure
      expect(fired).to contain_exactly(:failure)
      expect(result.error).to include("Payload can't be blank")
    end

    it "normalizes an aliased parent (subfield declared on: the alias) back to the wire key" do
      # The failed-parent set holds wire keys (:payload from the ActiveModel errors), but the
      # subfield's on: names the reader (:raw_payload) — `_root_wire_field` must map it back so the
      # derived-skip gate matches and the parent's user-facing message surfaces.
      action = build_axn do
        expects :payload, type: Hash, as: :raw_payload, user_facing: true
        expects :id, on: :raw_payload
        def call = nil
      end
      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to include("Payload can't be blank")
    end

    it "normalizes a subfield rooted at another subfield of the user-facing parent" do
      action = build_axn do
        expects :payload, type: Hash, user_facing: true
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta # rooted at a subfield, which is itself rooted at the user-facing parent
        def call = nil
      end
      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to include("Payload can't be blank")
    end
  end

  describe "an extractable user_facing parent still runs its independent subfield checks" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        # payload is a valid Hash (so payload.id IS extractable) but fails its own custom validation.
        # Its subfield :id is the wrong type — an *independent* dev-facing violation, not one derived
        # from a broken parent — so it must still dominate and page.
        expects :payload, type: Hash, user_facing: true, validate: ->(_h) { "is not allowed" }
        expects :id, on: :payload, type: Integer

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
    end

    it "lets an independent dev-facing subfield violation dominate the extractable parent's failure" do
      result = action.call(payload: { id: "x" })
      expect(result.outcome).to be_exception
      expect(fired).to contain_exactly(:exception)
    end

    it "still surfaces the parent's user-facing message when its subfields are clean" do
      result = action.call(payload: { id: 5 })
      expect(result.outcome).to be_failure
      expect(result.error).to include("Payload is not allowed")
    end
  end

  describe "the derived-skip is gated to the failed user_facing parent's own subfields" do
    it "still pages a dev-facing subfield error whose parent is an unrelated absent optional field" do
      # :note is the (blank) user-facing field; :payload is a *separate* optional field that's absent,
      # so its required subfield :id can't resolve. That subfield error is independent of the
      # user-facing :note failure — :payload is not a failed user-facing parent — so it stays
      # dev-facing (exactly as it would with no user_facing field in play), rather than being
      # masked into an on_failure result.
      fired = []
      recorder = fired
      action = build_axn do
        expects :note, user_facing: true
        expects :payload, optional: true
        expects :id, on: :payload, type: Integer

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }

        def call = nil
      end
      result = action.call # :note blank AND :payload absent
      expect(result.outcome).to be_exception
      expect(fired).to contain_exactly(:exception)
    end

    it "does not swallow a real error raised by a subfield reader as a derived skip" do
      # :payload is present and unrelated to the blank user-facing :note, but reading payload.id
      # raises a genuine bug. That must surface as a dev-facing exception, not be misread as
      # "unextractable" and skipped behind the user-facing message.
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

    it "rejects user_facing: combined with on: (subfields are dev-facing)" do
      expect do
        build_axn { expects(:id, on: :event_params, user_facing: true) }
      end.to raise_error(ArgumentError, /user_facing: is not supported with on:/)
    end
  end
end
