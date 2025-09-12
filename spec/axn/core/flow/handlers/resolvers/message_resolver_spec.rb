# frozen_string_literal: true

RSpec.describe Axn::Core::Flow::Handlers::Resolvers::MessageResolver do
  let(:registry) { Axn::Core::Flow::Handlers::Registry.empty }
  let(:action) { double("action") }
  let(:exception) { nil }
  let(:resolver) { described_class.new(registry, :success, action:, exception:) }

  describe "#resolve_message" do
    let(:descriptor1) { double("descriptor1", matches?: true, handler: nil, prefix: nil) }
    let(:descriptor2) { double("descriptor2", matches?: true, handler: nil, prefix: nil) }

    before do
      allow(resolver).to receive(:message_from).with(descriptor1).and_return("Message 1")
      allow(resolver).to receive(:message_from).with(descriptor2).and_return("Message 2")
      allow(resolver).to receive(:message_from).with(nil).and_return(nil)
    end

    it "returns the first matching message" do
      allow(resolver).to receive(:matching_entries).and_return([descriptor1, descriptor2])
      expect(resolver.resolve_message).to eq("Message 1")
    end

    it "falls back to default message when no matching message found" do
      allow(resolver).to receive(:matching_entries).and_return([])
      allow(resolver).to receive(:fallback_message).and_return("Default message")
      expect(resolver.resolve_message).to eq("Default message")
    end
  end

  describe "#resolve_default_message" do
    let(:descriptor) { double("descriptor", handler: "handler", prefix: nil, static?: true) }

    before do
      allow(resolver).to receive(:message_from).with(descriptor).and_return("Default message")
      allow(resolver).to receive(:message_from).with(nil).and_return(nil)
    end

    it "returns message from first available handler" do
      allow(resolver).to receive(:candidate_entries).and_return([descriptor])
      expect(resolver.resolve_default_message).to eq("Default message")
    end

    it "falls back to default message when no handler found" do
      allow(resolver).to receive(:candidate_entries).and_return([])
      allow(resolver).to receive(:fallback_message).and_return("Fallback")
      expect(resolver.resolve_default_message).to eq("Fallback")
    end
  end

  describe "message ordering consistency" do
    let(:static_descriptor) { double("static", handler: "static_handler", prefix: nil, static?: true, matches?: true) }
    let(:conditional_descriptor) { double("conditional", handler: "conditional_handler", prefix: nil, static?: false, matches?: false) }
    let(:prefix_only_descriptor) { double("prefix_only", handler: nil, prefix: "Prefix: ", static?: true, matches?: true) }

    before do
      # Mock the message_from method to return different messages
      allow(resolver).to receive(:message_from).with(static_descriptor).and_return("Static message")
      allow(resolver).to receive(:message_from).with(conditional_descriptor).and_return("Conditional message")
      allow(resolver).to receive(:message_from).with(prefix_only_descriptor).and_return("Prefix: Static message")

      # Mock Invoker.call for default_descriptor tests
      allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Handler message")
    end

    context "when processing candidate_entries" do
      it "processes entries in first-defined-first order for find_default_descriptor" do
        # Registry stores in last-defined-first order, so we expect the order to be reversed
        # when we call .for(event_type)
        allow(resolver).to receive(:candidate_entries).and_return([conditional_descriptor, static_descriptor])

        # Should return the first static descriptor that has a handler and produces a message
        expect(resolver.send(:default_descriptor)).to eq(static_descriptor)
      end

      it "processes entries in first-defined-first order for default_descriptor" do
        allow(resolver).to receive(:candidate_entries).and_return([conditional_descriptor, static_descriptor])

        # Should find the first message from other descriptors
        result = resolver.send(:default_descriptor)
        expect(result).to eq(static_descriptor)
      end

      it "maintains consistent ordering between both methods" do
        # Test with multiple descriptors to ensure consistent behavior
        descriptor_a = double("a", handler: "handler_a", prefix: nil, static?: true, matches?: true)
        descriptor_b = double("b", handler: "handler_b", prefix: nil, static?: true, matches?: true)
        descriptor_c = double("c", handler: "handler_c", prefix: nil, static?: true, matches?: true)

        allow(resolver).to receive(:message_from).with(descriptor_a).and_return("Message A")
        allow(resolver).to receive(:message_from).with(descriptor_b).and_return("Message B")
        allow(resolver).to receive(:message_from).with(descriptor_c).and_return("Message C")

        allow(resolver).to receive(:candidate_entries).and_return([descriptor_a, descriptor_b, descriptor_c])

        # Both methods should process in the same order
        expect(resolver.send(:default_descriptor)).to eq(descriptor_a)
        expect(resolver.send(:default_descriptor)).to eq(descriptor_a)
      end

      it "skips conditional descriptors when finding default" do
        allow(resolver).to receive(:candidate_entries).and_return([conditional_descriptor, static_descriptor])

        # Should skip conditional descriptor and return static descriptor
        expect(resolver.send(:default_descriptor)).to eq(static_descriptor)
      end

      it "skips descriptors without handlers when finding default" do
        # Create a descriptor with no handler but with a prefix
        no_handler_descriptor = double("no_handler", handler: nil, prefix: "Prefix: ", static?: true, matches?: true)
        allow(resolver).to receive(:message_from).with(no_handler_descriptor).and_return(nil)

        allow(resolver).to receive(:candidate_entries).and_return([no_handler_descriptor, static_descriptor])

        # Should skip the no-handler descriptor and return static descriptor
        expect(resolver.send(:default_descriptor)).to eq(static_descriptor)
      end

      it "demonstrates why handler check prevents infinite loops" do
        # Create a prefix-only descriptor that would cause issues without handler check
        prefix_only = double("prefix_only", handler: nil, prefix: "Error: ", static?: true, matches?: true)

        # Mock message_from to simulate what would happen in reality
        allow(resolver).to receive(:message_from).with(prefix_only).and_return(nil)

        allow(resolver).to receive(:candidate_entries).and_return([prefix_only, static_descriptor])

        # Should skip prefix_only and return static_descriptor
        result = resolver.send(:default_descriptor)
        expect(result).to eq(static_descriptor)
        expect(result).not_to eq(prefix_only)
      end
    end

    context "with prefix-only descriptors" do
      it "finds default message content from other descriptors in correct order" do
        allow(resolver).to receive(:candidate_entries).and_return([conditional_descriptor, static_descriptor])

        # When a prefix-only descriptor needs a default message, it should find the first available
        result = resolver.send(:default_descriptor)
        expect(result).to eq(static_descriptor)
      end

      it "skips the current descriptor when searching for default content" do
        allow(resolver).to receive(:candidate_entries).and_return([prefix_only_descriptor, static_descriptor])

        # Should skip prefix_only_descriptor and find static_descriptor's message
        result = resolver.send(:default_descriptor)
        expect(result).to eq(static_descriptor)
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

  describe "message_from method" do
    let(:descriptor) { double("descriptor") }

    context "with handler" do
      before do
        allow(descriptor).to receive(:handler).and_return("handler")
        allow(descriptor).to receive(:prefix).and_return(nil)
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Handler message")
      end

      it "invokes handler and returns message" do
        result = resolver.send(:message_from, descriptor)
        expect(result).to eq("Handler message")
      end

      it "combines prefix with handler message when prefix exists" do
        allow(descriptor).to receive(:prefix).and_return("Prefix: ")
        result = resolver.send(:message_from, descriptor)
        expect(result).to eq("Prefix: Handler message")
      end
    end

    context "with prefix only" do
      before do
        allow(descriptor).to receive(:handler).and_return(nil)
        allow(descriptor).to receive(:prefix).and_return("Prefix: ")
      end

      it "uses exception message when exception exists" do
        exception_resolver = described_class.new(registry, :error, action:, exception: StandardError.new("Error message"))
        result = exception_resolver.send(:message_from, descriptor)
        expect(result).to eq("Prefix: Error message")
      end

      it "finds default message content from other descriptors for success messages" do
        other_descriptor = double("other", handler: "other_handler", prefix: nil, static?: true, matches?: true)
        allow(resolver).to receive(:candidate_entries).and_return([other_descriptor])
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Other message")

        result = resolver.send(:message_from, descriptor)
        expect(result).to eq("Prefix: Other message")
      end
    end

    context "with no handler and no prefix" do
      before do
        allow(descriptor).to receive(:handler).and_return(nil)
        allow(descriptor).to receive(:prefix).and_return(nil)
      end

      it "returns exception message when exception exists" do
        exception_resolver = described_class.new(registry, :error, action:, exception: StandardError.new("Error message"))
        result = exception_resolver.send(:message_from, descriptor)
        expect(result).to eq("Error message")
      end

      it "returns nil when no exception exists" do
        result = resolver.send(:message_from, descriptor)
        expect(result).to be_nil
      end
    end

    context "with no handler but with prefix" do
      let(:prefix_only_descriptor) { double("prefix_only", handler: nil, prefix: "Error: ") }

      it "returns prefix + exception message when exception exists" do
        exception_resolver = described_class.new(registry, :error, action:, exception: StandardError.new("Network error"))
        result = exception_resolver.send(:message_from, prefix_only_descriptor)
        expect(result).to eq("Error: Network error")
      end

      it "returns nil for success messages when no exception exists" do
        # This demonstrates why prefix-only descriptors without handlers are problematic for defaults
        result = resolver.send(:message_from, prefix_only_descriptor)
        expect(result).to be_nil
      end
    end

    context "with callable prefixes" do
      let(:descriptor) { double("descriptor", handler: "handler", prefix:) }
      let(:exception) { StandardError.new("Test error") }
      let(:exception_resolver) { described_class.new(registry, :error, action:, exception:) }

      before do
        allow(descriptor).to receive(:handler).and_return("handler")
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Handler message")
        # Mock Invoker.call for prefix resolution
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).with(
          action:, handler: prefix, exception:, operation: "determining prefix callable",
        ).and_return(prefix_result)
      end

      let(:prefix_result) { "Prefix: " }

      context "with symbol prefix" do
        let(:prefix) { :prefix_method }
        let(:prefix_result) { "Symbol: " }

        before do
          allow(action).to receive(:respond_to?).with(:prefix_method, true).and_return(true)
          allow(action).to receive(:prefix_method).and_return("Symbol: ")
        end

        it "calls the symbol method on the action" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Symbol: Handler message")
          expect(Axn::Core::Flow::Handlers::Invoker).to have_received(:call).with(
            action:, handler: :prefix_method, exception:, operation: "determining prefix callable",
          )
        end
      end

      context "with callable prefix that accepts exception keyword" do
        let(:prefix) { ->(exception:) { "Exception #{exception.class}: " } }
        let(:prefix_result) { "Exception StandardError: " }

        it "calls the callable with exception keyword" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Exception StandardError: Handler message")
          expect(Axn::Core::Flow::Handlers::Invoker).to have_received(:call).with(
            action:, handler: prefix, exception:, operation: "determining prefix callable",
          )
        end
      end

      context "with callable prefix that accepts positional exception" do
        let(:prefix) { ->(exception) { "Positional #{exception.class}: " } }
        let(:prefix_result) { "Positional StandardError: " }

        it "calls the callable with positional exception" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Positional StandardError: Handler message")
          expect(Axn::Core::Flow::Handlers::Invoker).to have_received(:call).with(
            action:, handler: prefix, exception:, operation: "determining prefix callable",
          )
        end
      end

      context "with callable prefix that accepts no arguments" do
        let(:prefix) { -> { "No args: " } }
        let(:prefix_result) { "No args: " }

        it "calls the callable with no arguments" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("No args: Handler message")
          expect(Axn::Core::Flow::Handlers::Invoker).to have_received(:call).with(
            action:, handler: prefix, exception:, operation: "determining prefix callable",
          )
        end
      end

      context "with callable that returns nil" do
        let(:prefix) { -> {} }
        let(:prefix_result) { nil }

        it "treats nil prefix as no prefix" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Handler message")
        end
      end

      context "with callable that returns empty string" do
        let(:prefix) { -> { "" } }
        let(:prefix_result) { "" }

        it "uses empty string prefix" do
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Handler message")
        end
      end

      context "with callable that raises an error" do
        let(:prefix) { -> { raise "Prefix error" } }
        let(:prefix_result) { nil }

        before do
          allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).with(
            action:, handler: prefix, exception:, operation: "determining prefix callable",
          ).and_raise("Prefix error")
        end

        it "handles prefix resolution errors gracefully" do
          expect { exception_resolver.send(:message_from, descriptor) }.not_to raise_error
          result = exception_resolver.send(:message_from, descriptor)
          expect(result).to eq("Handler message") # Falls back to no prefix
        end
      end
    end

    context "with string prefixes (backward compatibility)" do
      let(:descriptor) { double("descriptor", handler: "handler", prefix: "String: ") }

      before do
        allow(descriptor).to receive(:handler).and_return("handler")
        allow(Axn::Core::Flow::Handlers::Invoker).to receive(:call).and_return("Handler message")
      end

      it "uses string prefix directly without invoking" do
        result = resolver.send(:message_from, descriptor)
        expect(result).to eq("String: Handler message")
        expect(Axn::Core::Flow::Handlers::Invoker).not_to have_received(:call).with(
          action:, handler: "String: ", exception:, operation: "determining prefix callable",
        )
      end
    end

    context "demonstrating why handler check is necessary" do
      it "shows that descriptors without handlers can return nil for success messages" do
        # This test demonstrates why the handler check in find_default_descriptor is crucial
        prefix_only = double("prefix_only", handler: nil, prefix: "Success: ", static?: true, matches?: true)

        # For success messages without exceptions, prefix-only descriptors return nil
        success_resolver = described_class.new(registry, :success, action:, exception: nil)
        result = success_resolver.send(:message_from, prefix_only)

        # This would cause find_default_descriptor to fail if we didn't check for handler
        expect(result).to be_nil
      end
    end
  end
end
