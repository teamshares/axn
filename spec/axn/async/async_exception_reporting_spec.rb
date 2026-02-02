# frozen_string_literal: true

RSpec.describe "Per-class async_exception_reporting" do
  describe ".async_exception_reporting DSL" do
    it "sets the per-class exception reporting mode" do
      action = build_axn do
        async_exception_reporting :only_exhausted
      end

      expect(action._async_exception_reporting).to eq(:only_exhausted)
    end

    it "raises ArgumentError for invalid modes" do
      expect do
        build_axn do
          async_exception_reporting :invalid_mode
        end
      end.to raise_error(ArgumentError, /must be one of/)
    end

    it "accepts :every_attempt" do
      action = build_axn do
        async_exception_reporting :every_attempt
      end

      expect(action._async_exception_reporting).to eq(:every_attempt)
    end

    it "accepts :first_and_exhausted" do
      action = build_axn do
        async_exception_reporting :first_and_exhausted
      end

      expect(action._async_exception_reporting).to eq(:first_and_exhausted)
    end

    it "accepts :only_exhausted" do
      action = build_axn do
        async_exception_reporting :only_exhausted
      end

      expect(action._async_exception_reporting).to eq(:only_exhausted)
    end

    it "accepts nil to clear the override" do
      action = build_axn do
        async_exception_reporting :only_exhausted
        async_exception_reporting nil
      end

      expect(action._async_exception_reporting).to be_nil
    end
  end

  describe "inheritance" do
    it "child classes inherit parent's async_exception_reporting setting" do
      parent = build_axn do
        async_exception_reporting :only_exhausted
      end

      child = Class.new(parent)

      expect(child._async_exception_reporting).to eq(:only_exhausted)
    end

    it "child classes can override parent's setting" do
      parent = build_axn do
        async_exception_reporting :only_exhausted
      end

      child = Class.new(parent) do
        async_exception_reporting :every_attempt
      end

      expect(parent._async_exception_reporting).to eq(:only_exhausted)
      expect(child._async_exception_reporting).to eq(:every_attempt)
    end

    it "child classes can clear parent's setting to use global config" do
      parent = build_axn do
        async_exception_reporting :only_exhausted
      end

      child = Class.new(parent) do
        async_exception_reporting nil
      end

      expect(parent._async_exception_reporting).to eq(:only_exhausted)
      expect(child._async_exception_reporting).to be_nil
    end
  end

  describe "fallback to global config" do
    it "returns nil by default (no override)" do
      action = build_axn

      expect(action._async_exception_reporting).to be_nil
    end

    it "nil causes RetryContext to use global config" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)
      retry_context = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 1, max_retries: 25)

      # nil mode should fall back to global config
      expect(retry_context.should_trigger_on_exception?(nil)).to eq(
        retry_context.should_trigger_on_exception?(:first_and_exhausted),
      )
    end
  end

  describe "integration with _trigger_on_exception" do
    let(:retry_context) { Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 5, max_retries: 25) }

    before do
      allow(Axn::Async::CurrentRetryContext).to receive(:current).and_return(retry_context)
    end

    after do
      allow(Axn::Async::CurrentRetryContext).to receive(:current).and_call_original
    end

    context "when action has per-class override :only_exhausted" do
      it "does not trigger exception on intermediate attempts" do
        action = build_axn do
          async_exception_reporting :only_exhausted
        end

        # Mock the global config to use :first_and_exhausted (which would trigger on first)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)

        on_exception_called = false
        allow(Axn.config).to receive(:on_exception) do
          on_exception_called = true
        end

        # Attempt 5 of 25 - should NOT trigger with :only_exhausted
        action.call

        expect(on_exception_called).to be false
      end
    end

    context "when action has per-class override :every_attempt" do
      it "triggers exception on every attempt even when global is :only_exhausted" do
        action = build_axn do
          async_exception_reporting :every_attempt

          def call
            raise "Test error"
          end
        end

        # Mock the global config to use :only_exhausted (which would NOT trigger on intermediate)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        on_exception_called = false
        original_on_exception = Axn.config.method(:on_exception)
        allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
          on_exception_called = true
          original_on_exception.call(*args, **kwargs)
        end

        # Attempt 5 of 25 - should trigger with :every_attempt override
        action.call

        expect(on_exception_called).to be true
      end
    end

    context "when action has no per-class override" do
      it "falls back to global config behavior" do
        action = build_axn do
          def call
            raise "Test error"
          end
        end

        # Global config is :only_exhausted - should NOT trigger on intermediate
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        on_exception_called = false
        original_on_exception = Axn.config.method(:on_exception)
        allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
          on_exception_called = true
          original_on_exception.call(*args, **kwargs)
        end

        # Attempt 5 of 25 - should NOT trigger with global :only_exhausted
        action.call

        expect(on_exception_called).to be false
      end
    end
  end
end
