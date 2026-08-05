# frozen_string_literal: true

RSpec.describe Axn::Core::Flow::Handlers::Resolvers::MessageResolver do
  let(:registry) { Axn::Core::Flow::Handlers::Registry.empty }
  let(:action) { double("action") }
  let(:exception) { nil }
  let(:resolver) { described_class.new(registry, :success, action:, exception:) }

  def build_descriptor(handler:, standalone: nil, join: nil, if: nil, unless: nil)
    Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
      handler:,
      standalone:,
      join:,
      if: binding.local_variable_get(:if),
      unless: binding.local_variable_get(:unless),
    )
  end

  describe "#resolve_message" do
    it "returns the first matching message body" do
      descriptor = build_descriptor(handler: "Message 1")
      allow(resolver).to receive(:matching_entries).and_return([descriptor])
      allow(resolver).to receive(:body_for).with(descriptor).and_return("Message 1")
      allow(resolver).to receive(:reason?).and_return(true) # the descriptor IS a selectable reason
      expect(resolver.resolve_message).to eq("Message 1")
    end

    it "falls back to default message when no matching message found" do
      allow(resolver).to receive(:matching_entries).and_return([])
      allow(resolver).to receive(:base_message).and_return(nil)
      allow(resolver).to receive(:fallback_message).and_return("Default message")
      expect(resolver.resolve_message).to eq("Default message")
    end
  end

  describe "#resolve_default_message" do
    it "returns base_message when available" do
      allow(resolver).to receive(:base_message).and_return("Base message")
      expect(resolver.resolve_default_message).to eq("Base message")
    end

    it "falls back to fallback_message when no base" do
      allow(resolver).to receive(:base_message).and_return(nil)
      allow(resolver).to receive(:fallback_message).and_return("Fallback")
      expect(resolver.resolve_default_message).to eq("Fallback")
    end
  end

  describe "message ordering consistency" do
    context "base_descriptor selection" do
      it "picks the last-defined static unconditional error entry (most-recent-first in registry)" do
        # registry stores most-recent-first, so first-in-array was defined last
        error_resolver = described_class.new(registry, :error, action:, exception:)
        d1 = build_descriptor(handler: "First") # registered first → last in array
        d2 = build_descriptor(handler: "Second") # registered last → first in array
        allow(error_resolver).to receive(:candidate_entries).and_return([d2, d1])
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Second")

        expect(error_resolver.send(:base_descriptor)).to eq(d2)
      end

      it "skips conditional descriptors when finding base" do
        error_resolver = described_class.new(registry, :error, action:, exception:)
        conditional = build_descriptor(handler: "cond", if: ArgumentError)
        static = build_descriptor(handler: "static")
        allow(error_resolver).to receive(:candidate_entries).and_return([conditional, static])
        expect(error_resolver.send(:base_descriptor)).to eq(static)
      end

      it "skips descriptors without handlers when finding base" do
        error_resolver = described_class.new(registry, :error, action:, exception:)
        no_handler = double("no_handler", handler: nil, static?: true, standalone?: true)
        static = build_descriptor(handler: "static")
        allow(error_resolver).to receive(:candidate_entries).and_return([no_handler, static])
        expect(error_resolver.send(:base_descriptor)).to eq(static)
      end

      it "skips standalone: false descriptors when finding base" do
        error_resolver = described_class.new(registry, :error, action:, exception:)
        promoted_d = build_descriptor(handler: "promoted", standalone: false, if: ArgumentError)
        base_d = build_descriptor(handler: "base")
        allow(error_resolver).to receive(:candidate_entries).and_return([promoted_d, base_d])
        expect(error_resolver.send(:base_descriptor)).to eq(base_d)
      end

      it "returns the static descriptor for success event_type (base concept now applies to success too)" do
        success_resolver = described_class.new(registry, :success, action:, exception:)
        static = build_descriptor(handler: "static")
        allow(success_resolver).to receive(:candidate_entries).and_return([static])
        expect(success_resolver.send(:base_descriptor)).to eq(static)
      end
    end
  end

  describe "fallback behavior" do
    it "returns success default for success event type" do
      success_resolver = described_class.new(registry, :success, action:, exception:)
      expect(success_resolver.send(:fallback_message)).to eq("Action completed successfully")
    end

    it "returns error default for error event type" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      expect(error_resolver.send(:fallback_message)).to eq("Something went wrong")
    end
  end

  describe "#body_for (was message_from)" do
    let(:exception_resolver) { described_class.new(registry, :error, action:, exception: StandardError.new("Error message")) }

    context "with handler" do
      before do
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Handler message")
      end

      it "invokes handler and returns message" do
        descriptor = build_descriptor(handler: "handler")
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Handler message")
      end
    end

    context "with no handler" do
      it "returns exception message when exception exists" do
        descriptor = double("descriptor", handler: nil)
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Error message")
      end

      it "returns nil when no exception exists" do
        descriptor = double("descriptor", handler: nil)
        result = resolver.send(:body_for, descriptor)
        expect(result).to be_nil
      end

      # This branch reads `exception.message` with no guard of its own — no rescue wraps it, and the
      # caller chain (Result#error -> resolve_message -> ... -> body_for) has none either, so a raising
      # `#message` would replace the settled `result.error` read outright.
      it "does not let a raising #message escape" do
        hostile = Class.new(StandardError) do
          def message = raise(NotImplementedError, "message explodes")
        end.new
        hostile_resolver = described_class.new(registry, :error, action:, exception: hostile)
        descriptor = double("descriptor", handler: nil)

        expect { hostile_resolver.send(:body_for, descriptor) }.not_to raise_error
      end
    end
  end

  describe "#with_base" do
    it "returns reason combined with base when base_message present" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return("Base")
      allow(error_resolver).to receive(:join).and_return(": ")
      expect(error_resolver.with_base("reason")).to eq("Base: reason")
    end

    it "returns reason as-is when no base_message" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return(nil)
      expect(error_resolver.with_base("reason")).to eq("reason")
    end
  end
end

RSpec.describe "join: Proc raise-safety" do
  it "falls back to the default join when the Proc raises" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { raise "kaboom in join" }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  # This runs from `result.error` DURING settlement, so an exception slipping past the fallback aborts
  # settling after the exception is recorded but before on_error/on_failure/on_exception and the global
  # report — and raises again on every later `result.error` read.
  it "falls back, and keeps settlement intact, when the Proc raises a non-StandardError" do
    events = []
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { raise SystemStackError }
      on_error { events << :on_error }
      on_failure { events << :on_failure }
      def call = fail!("inner")
    end
    allow(action).to receive(:warn)

    result = action.call

    expect(result.error).to eq("Outer: inner")
    expect(result.error).to eq("Outer: inner") # a second read must not retry the joiner and raise
    expect(events).to eq(%i[on_error on_failure])
  end

  it "falls back to the default join when the Proc has the wrong arity (lambda)" do
    action = build_axn do
      error "Outer", join: ->(only_one) { only_one }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  it "falls back to the default join when the Proc returns a non-String" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { 42 }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  it "falls back to the default join when the Proc raises (success/done! path)" do
    action = build_axn do
      success "All good", join: ->(_base, _reason) { raise "kaboom in join" }
      def call = done!("from cache")
    end
    expect(action.call.success).to eq("All good: from cache")
  end

  it "falls back to the default join when a non-lambda Proc has the wrong arity" do
    action = build_axn do
      error "Outer", join: proc { |base| base } # non-lambda, arity 1 — silently drops reason today
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  it "supports a non-Proc callable object as join:" do
    joiner = Class.new do
      def call(base, reason) = "#{base} (#{reason})"
    end.new
    action = build_axn do
      error "Outer", join: joiner
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer (inner)")
  end

  it "falls back to the default join when the Proc returns a blank String" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { "" }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  # The non-String branch NAMES the returned value's class, and the value is caller-supplied — so the name
  # comes from the same funnel the rescue below uses rather than from `result.class`, which the value owns.
  it "falls back to the default join, naming the class, when the Proc returns a non-String" do
    returned = Class.new do
      def self.name = raise(NotImplementedError, "name explodes")
      def class = raise(NotImplementedError, "class explodes")
    end.new
    warnings = []
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { returned }
      def call = fail!("inner")
    end
    allow_any_instance_of(action).to receive(:warn) { |_, msg| warnings << msg }

    expect(action.call.error).to eq("Outer: inner")
    expect(warnings).to include(a_string_matching(/join: callable returned .+ \(expected a non-blank String\)/))
  end

  # The rescue clause that reports the join Proc's raise builds its warn line from the raised
  # exception's own `#class`/`#message` — a read that is NOT itself guarded by anything further out:
  # `resolve_message` runs from `Result#error` with no enclosing rescue, so a hostile `#message` here
  # replaces the settled `result.error` read with the hostile exception instead of degrading to a log line.
  it "falls back to the default join when the raised exception itself has a raising #message" do
    hostile = Class.new(StandardError) do
      def message = raise(NotImplementedError, "message explodes")
    end
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { raise hostile, "boom" }
      def call = fail!("inner")
    end

    result = action.call
    expect { result.error }.not_to raise_error
    expect(result.error).to eq("Outer: inner")
  end

  # The warn line's OWN prose contains an em dash (" — using default join"), a genuine multi-byte UTF-8
  # character — not ASCII-only. So an ORDINARY exception (no hostile #message override) whose message
  # holds bytes with no UTF-8 rendering is enough to collide: joining two fragments that are each
  # non-ASCII-only, in different encodings, raises Encoding::CompatibilityError from the warn line
  # itself — no unusual author required, just the raised exception's message and axn's own prose.
  it "falls back to the default join when the raised exception's message holds unrenderable bytes" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }
      def call = fail!("inner")
    end

    warnings = []
    allow(action).to receive(:warn) { |msg| warnings << msg }

    result = action.call
    expect { result.error }.not_to raise_error
    expect(result.error).to eq("Outer: inner")
    expect(warnings).to include(a_string_matching(/join: Proc raised ArgumentError: "bad\\xFF"/))
  end

  # Choosing WHICH join branch applies is itself a read of the caller's `join:` value, and it happens before
  # any of the guards above — so `respond_to?`/`is_a?` there escaped `.call` outright rather than costing the
  # separator. The branch is now decided from the hierarchy.
  #
  # `MessageDescriptor.build` already rejects a join that is neither a String nor callable, so what reaches
  # `combine` has answered those questions once, at declaration. That bounds this to a value whose answer is
  # NOT IDEMPOTENT — the same shape the repo has already been bitten by on `Exception#exception`, where an
  # implementation succeeding on its first call and raising on its second was not excluded by the object
  # having been raised once. Declaration passing is evidence about the first call and nothing else.
  it "does not re-ask the join: value which branch it belongs in" do
    hostile = Class.new do
      def initialize = @armed = false
      def arm! = @armed = true
      # Ruby's own signature — `respond_to?` takes the private flag positionally, so a keyword here would
      # not be the method Ruby dispatches.
      def respond_to?(name, include_private = false) = @armed ? raise(NotImplementedError, "respond_to? must not decide the branch") : super # rubocop:disable Style/OptionalBooleanParameter
      def is_a?(klass) = @armed ? raise(NotImplementedError, "is_a? must not decide the branch") : super
      def kind_of?(klass) = is_a?(klass)
      def call(base, reason) = "#{base} / #{reason}"
    end.new

    action = build_axn do
      error "Outer", join: hostile
      def call = fail!("inner")
    end
    hostile.arm!

    result = nil
    expect { result = action.call }.not_to raise_error
    expect(result.error).to eq("Outer / inner")
  end

  # An explicit "" is honored verbatim, which is why the String branch is tested BEFORE absence: `""` is
  # blank by every spelling of the question, so an absence test reached first would silently substitute ": ".
  it "still honors an explicit empty-String join" do
    action = build_axn do
      error "Outer", join: ""
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outerinner")
  end

  # Pinning why `combine` needs no callable probe of its own: a non-String, non-callable join never gets far
  # enough to be one of its branches.
  it "rejects a join: value that is neither a String nor callable at declaration" do
    expect { build_axn { error "Outer", join: 123 } }
      .to raise_error(ArgumentError, /join: must be a String or a callable/)
  end

  describe "the operands a join Proc receives" do
    # The Proc is handed rendered halves, so its own interpolation cannot dispatch a hostile `to_s`. That was
    # the one dispatch on this path axn could not contain by guarding: it happens inside the caller's block,
    # and the raise here is outside StandardError AND outside SWALLOWABLE_BEYOND_STANDARD_ERROR
    # (SystemStackError, ScriptError), so it escaped the rescue in `apply_join_proc` entirely.
    it "renders a reason whose to_s raises unswallowably, instead of letting the Proc dispatch it" do
      unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
      reason = Class.new do
        define_method(:to_s) { raise(unswallowable, "to_s must not be dispatched by the join Proc") }
      end.new

      action = build_axn do
        error "Outer", join: ->(base, r) { "#{base} <#{r}>" }
        define_method(:call) { fail!(reason) }
      end

      result = nil
      expect { result = action.call }.not_to raise_error

      # The unrenderable half degrades to its CLASS — the same fallback every other branch of the join
      # takes — and the Proc still composed around it.
      expect(result.error).to match(/\AOuter <.+>\z/)
    end

    it "hands the Proc Strings, so the documented recasing works" do
      action = build_axn do
        error "Outer", join: ->(base, reason) { "#{base} — #{reason.upcase}" }
        def call = fail!("inner")
      end

      expect(action.call.error).to eq("Outer — INNER")
    end

    # Non-ASCII on BOTH sides, which is what an Encoding::CompatibilityError actually needs: a Latin-1
    # reason against an all-ASCII template concatenates silently and would pass vacuously.
    it "renders a Latin-1 reason before the Proc joins it to non-ASCII prose" do
      latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1")
      action = build_axn do
        error "Outer", join: ->(base, reason) { "#{base} — #{reason} ✓" }
        define_method(:call) { fail!(latin1) }
      end

      result = nil
      expect { result = action.call }.not_to raise_error
      expect(result.error).to include("café")
      expect(result.error.encoding).to eq(Encoding::UTF_8)
    end
  end

  # The Proc's return value decides whether it is RETURNED as the message, so its blankness is read from its
  # own bytes rather than by dispatching `present?` — which a String subclass overrides as readily as `to_s`.
  it "does not let the returned String's own present? decide that it is a usable message" do
    liar = Class.new(String) do
      def present? = true
      def blank? = false
    end.new("   ")

    action = build_axn do
      error "Outer", join: ->(_base, _reason) { liar }
      def call = fail!("inner")
    end

    expect(action.call.error).to eq("Outer: inner")
  end
end

RSpec.describe "a message handler whose return value cannot answer whether it is blank" do
  # Whether a handler supplied a body at all was asked of the RETURN VALUE with `presence`, dispatching the
  # caller's own `blank?`. That runs while the failure is being settled and again on every later
  # `result.error` read, with no rescue over either: the settle path aborted (warning about a reporting
  # failure and settling the run as an `exception` outcome), and the read raised afresh every time.
  let(:unblankable) do
    Object.new.tap do |o|
      o.define_singleton_method(:empty?) { raise NotImplementedError, "empty? explodes" }
      o.define_singleton_method(:blank?) { raise NotImplementedError, "blank? explodes" }
      o.define_singleton_method(:to_s) { "the resolved body" }
    end
  end

  it "resolves a base error's body and keeps settlement intact" do
    body = unblankable
    events = []
    action = build_axn do
      error(-> { body })
      on_error { events << :on_error }
      on_exception { events << :on_exception }
      def call = raise("boom")
    end

    result = action.call

    expect(result.outcome.exception?).to be(true)
    expect { result.error }.not_to raise_error
    expect(result.error.to_s).to eq("the resolved body")
    expect(result.error.to_s).to eq("the resolved body") # a second read must not re-ask and raise
    expect(events).to eq(%i[on_error on_exception])
  end

  it "resolves a conditional error's body under a declared base" do
    body = unblankable
    action = build_axn do
      error "Charge failed"
      error(if: -> { true }) { body }
      def call = raise("boom")
    end

    expect(action.call.error).to eq("Charge failed: the resolved body")
  end

  it "resolves a success handler's body on the done! path" do
    body = unblankable
    action = build_axn do
      success(-> { body })
      def call = nil
    end

    result = action.call

    expect(result.ok?).to be(true)
    expect { result.success }.not_to raise_error
    expect(result.success.to_s).to eq("the resolved body")
  end
end
