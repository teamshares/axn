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

    # The handler's return value is the CALLER's object, and whether it counts as a message is decided while
    # the inbound failure is being classified. Asking that object `presence` there let it replace the failure
    # the declaration configured: the run settled as an `exception` outcome — firing the global report for
    # something marked the caller's fault — instead of as the user-facing failure.
    it "settles as the user-facing failure when the override cannot answer whether it is blank" do
      unanswerable = Object.new.tap do |o|
        o.define_singleton_method(:empty?) { raise NotImplementedError, "empty? explodes" }
        o.define_singleton_method(:blank?) { raise NotImplementedError, "blank? explodes" }
        o.define_singleton_method(:to_s) { "Please add a note" }
      end
      events = []
      action = build_axn do
        expects :note, user_facing: ->(_e) { unanswerable }
        on_failure { events << :on_failure }
        on_exception { events << :on_exception }
        def call = nil
      end

      result = action.call

      expect(result.outcome.failure?).to be(true)
      expect(result.error).to eq("Please add a note")
      expect(events).to eq([:on_failure])
    end

    # The same line renders the return value and lists it. Both dispatches are the caller's code: interpolating
    # a part calls its `to_s`, and `Kernel#Array` calls its `to_ary`. Either one raising settled the run as an
    # `exception` outcome — firing the global report for something marked the caller's fault — so both are
    # contained, and a return value that cannot render leaves the field's own validation message standing.
    it "settles as the user-facing failure when the override's own rendering raises" do
      unrenderable = Object.new.tap do |o|
        o.define_singleton_method(:to_s) { raise NotImplementedError, "to_s explodes" }
      end
      events = []
      action = build_axn do
        expects :note, user_facing: ->(_e) { unrenderable }
        on_failure { events << :on_failure }
        on_exception { events << :on_exception }
        def call = nil
      end

      result = action.call

      expect(result.outcome.failure?).to be(true)
      expect { result.error }.not_to raise_error
      expect(result.error).to eq("Note can't be blank")
      expect(events).to eq([:on_failure])
    end

    it "settles as the user-facing failure when the override cannot be coerced to a list" do
      unlistable = Object.new.tap do |o|
        o.define_singleton_method(:to_ary) { raise NotImplementedError, "to_ary explodes" }
        o.define_singleton_method(:to_s) { "Please add a note" }
      end
      events = []
      action = build_axn do
        expects :note, user_facing: ->(_e) { unlistable }
        on_failure { events << :on_failure }
        on_exception { events << :on_exception }
        def call = nil
      end

      result = action.call

      expect(result.outcome.failure?).to be(true)
      expect { result.error }.not_to raise_error
      expect(result.error).to eq("Note can't be blank")
      expect(events).to eq([:on_failure])
    end

    # The literal `user_facing: "…"` branch is listed by hand precisely so a String subclass carrying a
    # `to_ary` never reaches `Kernel#Array`. A HANDLER returning the same object went through it, and
    # `Kernel#Array` prefers `to_ary` — so the text was expanded into whatever that method answered and
    # dropped, leaving the field's validation message where the override should have been. Contained, but a
    # String is one part however it arrived.
    it "surfaces a handler's String return whose class also defines to_ary" do
      sneaky = Class.new(String) do
        def to_ary = []
      end.new("Please add a note")

      action = build_axn do
        expects :note, user_facing: ->(_e) { sneaky }
        def call = nil
      end

      result = action.call

      expect(result.outcome.failure?).to be(true)
      expect(result.error).to eq("Please add a note")
    end

    # A handler that resolves to nothing falls back to the field's own message, and that message is Latin-1
    # when the declared name is — so this pins that both routes to it reach the caller as the same UTF-8 text.
    #
    # It does NOT pin `_rendered_parts` specifically, and that is worth saying rather than implying: the join
    # in `_composed_user_facing_error` renders every part again, so whether the fallback hands back a rendered
    # or a raw Array is not observable here. That fix is a single-exit-shape cleanup, not a behaviour change
    # (verified by inverse mutation — reverting it changes nothing any caller can see).
    it "reaches the field's own message as the same UTF-8 text whether or not a handler resolved" do
      latin1_name = "n\xF4te".dup.force_encoding("ISO-8859-1").to_sym

      resolved = build_axn do
        expects latin1_name, user_facing: ->(_e) {}
        def call = nil
      end.call.error

      declared = build_axn do
        expects latin1_name, user_facing: true
        def call = nil
      end.call.error

      expect(resolved.encoding).to eq(Encoding::UTF_8)
      expect(resolved).to eq(declared)
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

    it "validates a raw ShapeConfig member's user_facing: grammar at construction (raw path shares the block path's check)" do
      # A raw shape: kwarg supplies pre-built ShapeConfigs that bypass _build_shape_member; the grammar
      # check lives in ShapeConfig's constructor, so a malformed value fails here rather than surfacing
      # as a literal runtime message ("123").
      expect do
        Axn::Core::Contract::ShapeConfig.new(field: :status, validations: { type: { klass: String } }, user_facing: 123)
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    # The constructor is an early error, not the gate: a member of any other class never runs it, and a
    # `ShapeConfig` copy does not either on a Ruby whose `Data#with` skips a custom `initialize`. The declaration
    # walk is where every member meets the grammar, so it is rejected before the class exists rather than on the
    # first call that happens to fail this member.
    it "rejects a malformed user_facing on a raw member at declaration, whatever the member's class" do
      [
        Struct.new(:field, :validations, :user_facing).new(:status, { type: { klass: String } }, 123),
        Data.define(:field, :validations, :user_facing).new(field: :status, validations: { type: { klass: String } }, user_facing: 123),
      ].each do |bad|
        expect do
          build_axn { expects :items, type: Hash, shape: { members: [bad] } }
        end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
      end
    end

    it "rejects a malformed user_facing on a derived ShapeConfig copy, before the copy can reach a contract" do
      original = Axn::Core::Contract::ShapeConfig.new(field: :status, validations: { type: { klass: String } })

      expect do
        copy = original.with(user_facing: 123)
        build_axn { expects :items, type: Hash, shape: { members: [copy] } }
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
    end

    it "never sees a malformed user_facing added to a raw member's nested shape AFTER declaration" do
      # A DECLARED contract cannot reach `ShapeValidator`'s grammar check at all: the declaration walk snapshots
      # every member — a duck-typed one included — into a `ShapeConfig` of axn's own, nested shape and all, so a
      # member appended to the caller's Hash afterwards is not in the contract. (The check that still runs there
      # is for a config ASSIGNED onto a class, which passes no walk — see the assigned-config describe below.)
      nested = { members: [], container: Hash }
      outer = Struct.new(:field, :validations).new(:line, { type: { klass: Hash }, shape: nested })
      action = build_axn do
        expects :order, type: Hash, shape: { members: [outer], container: Hash }
        def call = nil
      end
      nested[:members] << Struct.new(:field, :validations, :user_facing).new(:status, { type: { klass: String } }, 123)

      # The declared contract is "line is a Hash", exactly as it was when the class was defined — so the value
      # the appended member would have rejected is accepted, and no bogus rule is ever resolved.
      expect(action.call(order: { line: { status: 1 } })).to be_ok
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

    it "rejects even an explicit user_facing: false on an exposes shape member (key presence, matching top-level exposes)" do
      expect do
        build_axn do
          exposes :items, type: Array do
            field :status, type: String, user_facing: false
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

    it "rejects a user_facing: member supplied via a raw shape: kwarg on exposes (bypasses the block path)" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :status, validations: { type: { klass: String } }, user_facing: "surfaced")
      expect do
        build_axn do
          exposes :items, type: Hash, shape: { members: [member] }
        end
      end.to raise_error(ArgumentError, /`status` does not support user_facing: on exposes/)
    end

    it "rejects a user_facing: member nested inside a raw exposes shape (any depth)" do
      leaf = Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }, user_facing: "surfaced")
      line = Axn::Core::Contract::ShapeConfig.new(field: :line, validations: { type: { klass: Hash }, shape: { members: [leaf], container: Hash } })
      expect do
        build_axn do
          exposes :order, type: Hash, shape: { members: [line], container: Hash }
        end
      end.to raise_error(ArgumentError, /`sku` does not support user_facing: on exposes/)
    end
  end

  # `expects`/`exposes` is not the only way a class comes to hold a field config: the three config arrays are
  # writable, so a config ASSIGNED onto a class carries whatever its author built. Nothing about such a config
  # passed the declaration walk — and `user_facing:` is the one attribute whose unchecked value is not merely
  # stored but RESOLVED: a truthy value reclassifies the violation as user-facing (so the real contract bug is
  # never reported) and is then rendered as the caller's own error message.
  describe "a config assigned onto a class rather than declared" do
    def assigned(config)
      klass = build_axn { define_method(:call) { nil } } # define_method: inside a method body
      klass.internal_field_configs = [config].freeze
      klass
    end

    def duck_member(**readers)
      Class.new { readers.each { |name, value| define_method(name) { value } } }.new
    end

    def shaped_config(member)
      Axn::Core::Contract::FieldConfig.new(
        field: :payload, reader_as: :payload,
        validations: { type: { klass: Hash }, shape: { members: [member], container: Hash } }
      )
    end

    # Reading whether a member carries `user_facing:`/`method_call:` reads a CALLER's object here — this is the
    # path with no walk behind it — and it happens while the failure is being CLASSIFIED, which decides whether
    # the failure is reported at all. So the reader is asked for the VALUE (a bound `public_send`, absent told
    # from nil by the name the NoMethodError reports) rather than asked whether it has one.
    #
    # Deliberately an AVAILABILITY read overall, even though its first lookup is a method-table one: `member.field`
    # and `member.validations` are dispatched unconditionally a few lines away, so a member answering through
    # `method_missing` already works, and a table lookup reports such a method absent BY DESIGN. Were the table
    # lookup the whole read, it would silently stop honouring this member's `user_facing:` while its other readers
    # kept working — which is why absence there falls through to a dispatch rather than settling the question.
    it "honours a member whose readers answer through method_missing" do
      require "ostruct"
      member = OpenStruct.new(field: :status, validations: { presence: true }, user_facing: true) # rubocop:disable Style/OpenStructUse

      result = assigned(shaped_config(member)).call(payload: { "status" => "" })

      expect(result.outcome).to be_failure
      expect(Axn::ValidationError.user_facing?(result.exception)).to be(true)
    end

    # Raises rather than lies, so the example fails if the question is asked at all. Outside StandardError AND
    # outside SWALLOWABLE_BEYOND_STANDARD_ERROR, so a dispatch escapes `.call` instead of degrading.
    it "does not ask the member whether it carries the setting" do
      unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
      member = Struct.new(:field, :validations, :user_facing) do
        define_method(:respond_to?) { |*| raise(unswallowable, "respond_to? must not decide this") }
      end.new(:status, { presence: true }, true)

      result = nil
      expect { result = assigned(shaped_config(member)).call(payload: { "status" => "" }) }.not_to raise_error
      expect(result.outcome).to be_failure
      expect(Axn::ValidationError.user_facing?(result.exception)).to be(true)
    end

    # `respond_to?` is not the only hook a lookup can reach. Ruby consults `respond_to_missing?` whenever a name
    # asked of a VALUE is ABSENT, and absence is the branch this read exists to reach — it is how "carries no
    # `user_facing:`" is told from "carries nil". So a member defining that hook had the classifier running its
    # code, and this one raises outside StandardError, so it escapes `.call` in place of the settled failure.
    it "does not consult the member's respond_to_missing? about a setting it does not carry" do
      unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
      member = Struct.new(:field, :validations) do
        define_method(:respond_to_missing?) { |*| raise(unswallowable, "respond_to_missing? must not decide this") }
      end.new(:status, { presence: true })

      result = nil
      expect { result = assigned(shaped_config(member)).call(payload: { "status" => "" }) }.not_to raise_error
      expect(result.outcome).to be_exception
      expect(Axn::ValidationError.user_facing?(result.exception)).to be(false)
    end

    # The `method_missing` half without OpenStruct's real singleton accessors: nothing is in the method table, so
    # the first lookup reports absent and the dispatch fallback is what reads the setting. Distinct from the
    # OpenStruct example above, which the table lookup finds directly (`new_ostruct_member!` defines accessors) —
    # and from the schema fixtures elsewhere, which omit `respond_to_missing?`. Whether the hook is present must
    # not change the answer, because nothing on this path asks it.
    it "honours a member whose readers answer through method_missing behind a respond_to_missing?" do
      member = Class.new do
        def respond_to_missing?(reader, _include_private = false) = %i[field validations user_facing].include?(reader)

        def method_missing(reader, *_args)
          case reader
          when :field then :status
          when :validations then { presence: true }
          when :user_facing then true
          else super
          end
        end
      end.new

      result = assigned(shaped_config(member)).call(payload: { "status" => "" })

      expect(result.outcome).to be_failure
      expect(Axn::ValidationError.user_facing?(result.exception)).to be(true)
    end

    # A member with no such reader at all is the absent case: not opted in, so the failure stays DEV-facing and
    # settles as a reported `exception` outcome. The full contrast with the two above.
    it "treats a member with no user_facing reader as not opted in" do
      result = assigned(shaped_config(duck_member(field: :status, validations: { presence: true })))
               .call(payload: { "status" => "" })

      expect(result.outcome).to be_exception
      expect(Axn::ValidationError.user_facing?(result.exception)).to be(false)
    end

    # The FIELD half, closed where every stored field config passes: a FieldConfig cannot be CONSTRUCTED with a
    # value that is not a resolution rule, exactly as it cannot be constructed with a bogus `sensitive:`.
    it "cannot be built at all with a malformed field-level user_facing" do
      expect do
        Axn::Core::Contract::FieldConfig.new(field: :name, reader_as: :name, validations: { presence: true }, user_facing: 123)
      end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc \(got a value of class Integer\)/)
    end

    it "still accepts every value that IS a rule, and false" do
      [true, false, "surfaced", :some_method, ->(_e) { "x" }].each do |value|
        expect do
          Axn::Core::Contract::FieldConfig.new(field: :name, reader_as: :name, validations: { presence: true }, user_facing: value)
        end.not_to raise_error
      end
    end

    # The MEMBER half. A member is the caller's own object, so there is no constructor to hold it to the
    # grammar — the check lands where the value is first READ, which is also where it first decides anything.
    it "raises a dev-facing error rather than surfacing a malformed member user_facing to the caller" do
      action = assigned(shaped_config(duck_member(field: :inner, validations: { presence: true }, user_facing: 123)))

      result = action.call(payload: {})

      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to match(/user_facing: must be true, a String, a Symbol, or a Proc \(got a value of class Integer\)/)
      expect(result.error).not_to eq("123")
    end

    # The consequence that is worse than the wrong message: an unchecked truthy value makes the failure compose
    # as user-facing, so a real contract bug settles as a plain failure and is never reported.
    it "keeps the outcome reported rather than letting an unchecked value reclassify it" do
      action = assigned(shaped_config(duck_member(field: :inner, validations: { presence: true }, user_facing: 123)))

      expect(action.call(payload: {}).outcome).to be_exception
    end

    it "leaves a member that opts in with a real rule working" do
      action = assigned(shaped_config(duck_member(field: :inner, validations: { presence: true }, user_facing: "Needs an inner")))

      result = action.call(payload: {})

      expect(result.outcome).to be_failure
      expect(result.error).to eq("Needs an inner")
    end

    # Falsy is "not opted in" and has no grammar to meet — `nil` is what a member declaring the attribute
    # without setting it answers (a `Struct.new(:field, :validations, :user_facing)`), and `nil` is NOT in the
    # grammar, so checking it unconditionally would turn every such member into an ArgumentError. The failure
    # has to stay the ordinary dev-facing contract violation, which is why this asserts the exception CLASS:
    # an ArgumentError settles as "Something went wrong" too.
    it "treats a falsy member user_facing as not opted in, without checking it" do
      [nil, false].each do |value|
        action = assigned(shaped_config(duck_member(field: :inner, validations: { presence: true }, user_facing: value)))

        result = action.call(payload: {})

        expect(result.exception).to be_a(Axn::InboundValidationError)
        expect(result.error).to eq("Something went wrong")
      end
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

      it "derives the container for a raw shape: kwarg (no explicit container:), so it validates instead of crashing" do
        # A raw shape: kwarg bypasses the block form's _build_shape (which derives :container from
        # type:); _parse_field_validations now derives it the same way, so a container-less raw shape
        # validates like the block form instead of reaching ShapeValidator with a nil container
        # (value.is_a?(nil) → TypeError at call time).
        action = build_axn do
          expects :order, type: Hash, user_facing: "Order is required", shape: { members: [] }
          def call = nil
        end
        # A non-blank Hash validates (zero members) — previously raised TypeError on the nil container
        expect(action.call(order: { any: 1 }).outcome).to be_success
        # An empty Hash now surfaces the field's own user_facing presence failure, not a dev-facing TypeError
        result = action.call(order: {})
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Order is required")
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

    # The guard is a DECLARATION guard, so the value it is judging must not be able to raise INSTEAD of the
    # verdict — a `NotImplementedError` is outside StandardError and escapes every rescue above, so the
    # caller's exception replaced axn's own error entirely. Matches the `sensitive:` guard one method away.
    describe "a value that answers with code of its own" do
      let(:hostile) do
        Class.new do
          def is_a?(_klass) = raise(NotImplementedError, "is_a? should not decide this")
          def respond_to?(*) = raise(NotImplementedError, "respond_to? should not escape")
          def inspect = raise(NotImplementedError, "inspect should not build the message")
          def to_s = raise(NotImplementedError, "to_s should not build the message")
        end.new
      end

      it "reports axn's own ArgumentError rather than the value's exception" do
        value = hostile
        expect do
          build_axn { expects(:note, user_facing: value) }
        end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
      end

      it "names the offender by class rather than by running its #inspect" do
        expect do
          Axn::Core::Contract::FieldConfig.new(field: :note, reader_as: :note, validations: { presence: true }, user_facing: hostile)
        end.to raise_error(ArgumentError, /got a value of class #<Class:0x/)
      end

      it "holds a shape member to the same rule, whatever the member's class" do
        member = Struct.new(:field, :validations, :user_facing).new(:status, { presence: true }, hostile)

        expect do
          build_axn { expects :payload, type: Hash, shape: { members: [member], container: Hash } }
        end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
      end

      it "refuses rather than trusts a value whose `respond_to_missing?` raises" do
        raising_lookup = Class.new { def respond_to_missing?(*) = raise(NotImplementedError, "boom") }.new
        expect do
          build_axn { expects(:note, user_facing: raising_lookup) }
        end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
      end

      # The rescue is pinned to what axn absorbs everywhere else: a signal is nobody's fault and must pass
      # through, exactly as `best_effort` lets it.
      it "still lets a non-swallowable exception through untouched" do
        signalling = Class.new { def respond_to?(*) = raise(Interrupt) }.new
        expect do
          build_axn { expects(:note, user_facing: signalling) }
        end.to raise_error(Interrupt)
      end

      # The executor picks its String arm with `case`/`when` too, so a value claiming String through its own
      # `is_a?` was accepted here and then rendered as a literal at runtime — the split the guard exists to close.
      it "does not accept a value that claims String through its own #is_a?" do
        pretender = Class.new { def is_a?(klass) = klass == String }.new
        expect do
          build_axn { expects(:note, user_facing: pretender) }
        end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
      end

      # The dispatch is guarded, not removed: what may be declared is still exactly what the invoker will run,
      # so a duck-typed callable keeps working and resolves its message at runtime.
      it "still accepts (and invokes) a duck-typed callable the invoker can run" do
        callable = Class.new do
          def to_proc = proc { |_e| "from a duck" }
          def arity = 1
        end.new

        action = build_axn do
          expects :note, type: String, user_facing: callable
          def call = nil
        end

        expect(action.call(note: 1).error).to eq("from a duck")
      end
    end
  end
end
