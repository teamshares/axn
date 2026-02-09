# frozen_string_literal: true

RSpec.describe Axn::Util::GlobalExceptionReportingHelpers do
  describe ".format_hash_values" do
    it "leaves other values unchanged" do
      result = described_class.format_hash_values({
                                                    string: "hello",
                                                    number: 42,
                                                    boolean: true,
                                                    array: [1, 2, 3],
                                                    hash: { nested: "value" },
                                                  })

      expect(result).to eq({
                             string: "hello",
                             number: 42,
                             boolean: true,
                             array: [1, 2, 3],
                             hash: { nested: "value" },
                           })
    end
  end

  describe ".format_value_for_retry_command" do
    it "uses inspect for strings" do
      result = described_class.format_value_for_retry_command("Alice")
      expect(result).to eq("\"Alice\"")
    end

    it "uses inspect for numbers" do
      result = described_class.format_value_for_retry_command(42)
      expect(result).to eq("42")
    end

    it "uses inspect for booleans" do
      expect(described_class.format_value_for_retry_command(true)).to eq("true")
      expect(described_class.format_value_for_retry_command(false)).to eq("false")
    end

    it "uses inspect for arrays" do
      result = described_class.format_value_for_retry_command([1, 2, 3])
      expect(result).to eq("[1, 2, 3]")
    end

    it "uses inspect for hashes" do
      result = described_class.format_value_for_retry_command({ key: "value" })
      expect(result).to eq("{:key=>\"value\"}")
    end
  end

  describe ".retry_command" do
    let(:action) do
      build_axn do
        expects :name, type: String
        expects :age, type: Integer

        def call
          # no-op
        end
      end
    end

    it "generates a retry command with simple values" do
      # Use a named class so we can get the class name
      stub_const("TestRetryAction", action)

      instance = TestRetryAction.new(name: "Alice", age: 30)
      result = described_class.retry_command(
        action: instance,
        context: { name: "Alice", age: 30 },
      )

      expect(result).to eq('TestRetryAction.call(name: "Alice", age: 30)')
    end

    it "generates a retry command with no expectations" do
      no_expectations_action = build_axn do
        def call
          # no-op
        end
      end

      stub_const("NoExpectationsAction", no_expectations_action)

      instance = NoExpectationsAction.new
      result = described_class.retry_command(
        action: instance,
        context: {},
      )

      expect(result).to eq("NoExpectationsAction.call()")
    end

    it "returns nil for anonymous actions" do
      anonymous_action = build_axn do
        expects :name, type: String

        def call
          # no-op
        end
      end

      instance = anonymous_action.new(name: "test")

      # Stub class.name to return nil (simulating anonymous class)
      allow(instance.class).to receive(:name).and_return(nil)

      result = described_class.retry_command(
        action: instance,
        context: { name: "test" },
      )

      expect(result).to be_nil
    end
  end

  describe ".build_exception_context" do
    it "builds context with formatted inputs" do
      action_class = build_axn do
        expects :name, type: String
        expects :age, type: Integer

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.new(name: "Alice", age: 30)

      result = described_class.build_exception_context(action: instance)

      expect(result).to eq({
                             inputs: { name: "Alice", age: 30 },
                           })
    end

    it "includes async context when provided" do
      action_class = build_axn do
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.new(name: "Alice")
      retry_context = double("RetryContext", to_h: { attempt: 2, max_attempts: 5 })

      result = described_class.build_exception_context(
        action: instance,
        retry_context:,
      )

      expect(result).to eq({
                             inputs: { name: "Alice" },
                             async: { attempt: 2, max_attempts: 5 },
                           })
    end

    it "includes retry_command when _include_retry_command_in_exceptions is enabled" do
      action_class = build_axn do
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.new(name: "Alice")

      original_value = Axn.config._include_retry_command_in_exceptions
      begin
        Axn.config._include_retry_command_in_exceptions = true

        result = described_class.build_exception_context(action: instance)

        expect(result).to eq({
                               inputs: { name: "Alice" },
                               retry_command: 'TestAction.call(name: "Alice")',
                             })
      ensure
        Axn.config._include_retry_command_in_exceptions = original_value
      end
    end

    it "does not include retry_command when _include_retry_command_in_exceptions is disabled" do
      action_class = build_axn do
        expects :name, type: String

        def call
          # no-op
        end
      end

      stub_const("TestAction", action_class)

      instance = TestAction.new(name: "Alice")

      original_value = Axn.config._include_retry_command_in_exceptions
      begin
        Axn.config._include_retry_command_in_exceptions = false

        result = described_class.build_exception_context(action: instance)

        expect(result).to eq({
                               inputs: { name: "Alice" },
                             })
      ensure
        Axn.config._include_retry_command_in_exceptions = original_value
      end
    end
  end
end
