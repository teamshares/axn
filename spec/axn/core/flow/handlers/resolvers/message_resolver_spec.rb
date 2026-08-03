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
end
