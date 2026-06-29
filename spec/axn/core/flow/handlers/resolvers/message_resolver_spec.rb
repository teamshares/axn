# frozen_string_literal: true

RSpec.describe Axn::Core::Flow::Handlers::Resolvers::MessageResolver do
  let(:registry) { Axn::Core::Flow::Handlers::Registry.empty }
  let(:action) { double("action") }
  let(:exception) { nil }
  let(:resolver) { described_class.new(registry, :success, action:, exception:) }

  def build_descriptor(handler:, prefixed: false, join: nil, if: nil, unless: nil)
    Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
      handler:,
      prefixed:,
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
        no_handler = double("no_handler", handler: nil, static?: true, prefixed?: false)
        static = build_descriptor(handler: "static")
        allow(error_resolver).to receive(:candidate_entries).and_return([no_handler, static])
        expect(error_resolver.send(:base_descriptor)).to eq(static)
      end

      it "skips prefixed? descriptors when finding base" do
        error_resolver = described_class.new(registry, :error, action:, exception:)
        prefixed_d = build_descriptor(handler: "prefixed", prefixed: true, if: ArgumentError)
        base_d = build_descriptor(handler: "base")
        allow(error_resolver).to receive(:candidate_entries).and_return([prefixed_d, base_d])
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
    end
  end

  describe "#with_base_prefix" do
    it "returns reason prefixed with base when base_message present" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return("Base")
      allow(error_resolver).to receive(:join).and_return(": ")
      expect(error_resolver.with_base_prefix("reason")).to eq("Base: reason")
    end

    it "returns reason as-is when no base_message" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return(nil)
      expect(error_resolver.with_base_prefix("reason")).to eq("reason")
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
end
