# frozen_string_literal: true

RSpec.describe Axn::Core::Flow::Handlers::Resolvers::MessageResolver do
  let(:registry) { Axn::Core::Flow::Handlers::Registry.empty }
  let(:action) { double("action") }
  let(:exception) { nil }
  let(:resolver) { described_class.new(registry, :success, action:, exception:) }

  def build_descriptor(handler:, prefix: nil, prefixed: false, delimiter: nil, if: nil, unless: nil)
    Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
      handler:,
      prefix:,
      prefixed:,
      delimiter:,
      if: binding.local_variable_get(:if),
      unless: binding.local_variable_get(:unless),
    )
  end

  describe "#resolve_message" do
    it "returns the first matching message body" do
      descriptor = build_descriptor(handler: "Message 1")
      allow(resolver).to receive(:matching_entries).and_return([descriptor])
      allow(resolver).to receive(:body_for).with(descriptor).and_return("Message 1")
      allow(resolver).to receive(:base?).and_return(false)
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

      it "combines prefix with handler message when prefix exists" do
        descriptor = build_descriptor(handler: "handler", prefix: "Prefix: ")
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Prefix: Handler message")
      end
    end

    context "with no handler and no prefix" do
      it "returns exception message when exception exists" do
        descriptor = double("descriptor", handler: nil, prefix: nil)
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Error message")
      end

      it "returns nil when no exception exists" do
        descriptor = double("descriptor", handler: nil, prefix: nil)
        result = resolver.send(:body_for, descriptor)
        expect(result).to be_nil
      end
    end

    context "with prefix but no handler (prefix: keyword)" do
      it "returns prefix + exception message when exception exists" do
        prefix_only = double("prefix_only", handler: nil, prefix: "Error: ")
        result = exception_resolver.send(:body_for, prefix_only)
        expect(result).to eq("Error: Error message")
      end

      it "returns nil for success messages when no exception exists" do
        prefix_only = double("prefix_only", handler: nil, prefix: "Success: ")
        result = resolver.send(:body_for, prefix_only)
        expect(result).to be_nil
      end
    end

    context "with callable prefix:" do
      let(:exception) { StandardError.new("Test error") }
      let(:exception_resolver) { described_class.new(registry, :error, action:, exception:) }

      before do
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call)
          .with(hash_including(operation: "determining message callable"))
          .and_return("Handler message")
      end

      it "calls the symbol method on the action for symbol prefix" do
        descriptor = build_descriptor(handler: "handler", prefix: :prefix_method)
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call)
          .with(action:, handler: :prefix_method, exception:, operation: "determining prefix callable")
          .and_return("Symbol: ")
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Symbol: Handler message")
      end

      it "calls the callable with exception keyword" do
        prefix_callable = ->(exception:) { "Exception #{exception.class}: " }
        descriptor = build_descriptor(handler: "handler", prefix: prefix_callable)
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call)
          .with(action:, handler: prefix_callable, exception:, operation: "determining prefix callable")
          .and_return("Exception StandardError: ")
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Exception StandardError: Handler message")
      end

      it "treats nil prefix result as no prefix" do
        prefix_callable = -> {}
        descriptor = build_descriptor(handler: "handler", prefix: prefix_callable)
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call)
          .with(action:, handler: prefix_callable, exception:, operation: "determining prefix callable")
          .and_return(nil)
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Handler message")
      end

      it "handles prefix resolution errors gracefully" do
        prefix_callable = -> { raise "Prefix error" }
        descriptor = build_descriptor(handler: "handler", prefix: prefix_callable)
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call)
          .with(action:, handler: prefix_callable, exception:, operation: "determining prefix callable")
          .and_raise("Prefix error")
        expect { exception_resolver.send(:body_for, descriptor) }.not_to raise_error
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("Handler message")
      end

      it "uses string prefix directly without invoking" do
        descriptor = build_descriptor(handler: "handler", prefix: "String: ")
        result = exception_resolver.send(:body_for, descriptor)
        expect(result).to eq("String: Handler message")
        expect(Axn::Core::Flow::Handlers::Invoker).not_to have_received(:call).with(
          action:, handler: "String: ", exception:, operation: "determining prefix callable",
        )
      end
    end
  end

  describe "#with_base_prefix" do
    it "returns reason prefixed with base when base_message present" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return("Base")
      allow(error_resolver).to receive(:delimiter).and_return(": ")
      expect(error_resolver.with_base_prefix("reason")).to eq("Base: reason")
    end

    it "returns reason as-is when no base_message" do
      error_resolver = described_class.new(registry, :error, action:, exception:)
      allow(error_resolver).to receive(:base_message).and_return(nil)
      expect(error_resolver.with_base_prefix("reason")).to eq("reason")
    end
  end
end
