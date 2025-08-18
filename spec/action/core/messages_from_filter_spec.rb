# frozen_string_literal: true

RSpec.describe Action do
  let(:inner_action_class) do
    stub_const("InnerAction", Class.new do
      include Action

      expects :type

      error "default inner error"

      error if: ArgumentError do |e|
        "that wasn't a nice arg (#{e.message})"
      end

      def call
        raise ArgumentError, "handled" if type == :handled

        raise StandardError, "inner failed unhandled"
      end
    end)
  end

  let(:outer_action_class) do
    # Ensure InnerAction is defined first
    inner_action_class

    stub_const("OuterAction", Class.new do
      include Action

      expects :type

      error from: InnerAction do |e|
        "PREFIXED: #{e.message}"
      end

      def call
        InnerAction.call!(type:)
      end
    end)
  end

  let(:prefix_with_from_action_class) do
    # Ensure InnerAction is defined first
    inner_action_class

    stub_const("PrefixWithFromAction", Class.new do
      include Action

      expects :type

      error from: InnerAction, prefix: "Outer: " do |e|
        "wrapped: #{e.message}"
      end

      def call
        InnerAction.call!(type:)
      end
    end)
  end

  let(:prefix_only_from_action_class) do
    # Ensure InnerAction is defined first
    inner_action_class

    stub_const("PrefixOnlyFromAction", Class.new do
      include Action

      expects :type

      error from: InnerAction, prefix: "Outer: "

      def call
        InnerAction.call!(type:)
      end
    end)
  end

  let(:mixed_prefix_action_class) do
    # Ensure InnerAction is defined first
    inner_action_class

    stub_const("MixedPrefixAction", Class.new do
      include Action

      expects :type

      # Static fallback first
      error "Default error message"

      # Conditional with prefix only (falls back to exception message)
      error if: StandardError, prefix: "System Error: "

      # Conditional with prefix and custom message (more specific, defined after general)
      error if: ArgumentError, prefix: "Argument Error: " do |e|
        "Invalid input: #{e.message}"
      end

      # From with prefix and custom message
      error from: InnerAction, prefix: "Nested: " do |e|
        "Child failed: #{e.message}"
      end

      def call
        if type == :handled
          raise ArgumentError, "bad argument"
        elsif type == :unhandled
          raise StandardError, "system failure"
        elsif type == :nested
          InnerAction.call!(type: :handled)
        end
      end
    end)
  end

  it "can be configured on an action" do
    expect(outer_action_class.call(type: :handled).error).to eq(
      "PREFIXED: that wasn't a nice arg (handled)",
    )

    expect(outer_action_class.call(type: :unhandled).error).to eq(
      "PREFIXED: default inner error",
    )
  end

  it "supports prefix keyword for error messages" do
    action = build_action do
      expects :type

      error if: StandardError, prefix: "Baz: "
      error if: ArgumentError, prefix: "Foo: " do |e|
        "bar"
      end

      def call
        if type == :handled
          raise ArgumentError, "handled"
        elsif type == :unhandled
          raise StandardError, "unhandled"
        end
      end
    end

    expect(action.call(type: :handled).error).to eq("Foo: bar")
    expect(action.call(type: :unhandled).error).to eq("Baz: unhandled")
  end

  it "combines prefix with from keyword" do
    expect(prefix_with_from_action_class.call(type: :handled).error).to eq(
      "Outer: wrapped: that wasn't a nice arg (handled)",
    )

    expect(prefix_with_from_action_class.call(type: :unhandled).error).to eq(
      "Outer: wrapped: default inner error",
    )
  end

  it "combines prefix with from keyword (prefix only)" do
    expect(prefix_only_from_action_class.call(type: :handled).error).to eq(
      "Outer: that wasn't a nice arg (handled)",
    )

    expect(prefix_only_from_action_class.call(type: :unhandled).error).to eq(
      "Outer: default inner error",
    )
  end

  it "handles mixed prefix scenarios correctly" do
    # Test direct errors with prefix (no from: keyword needed)
    action = build_action do
      expects :type

      # Static fallback first
      error "Default error message"

      # Conditional with prefix only (falls back to exception message)
      error if: StandardError, prefix: "System Error: "

      # Conditional with prefix and custom message
      error if: ArgumentError, prefix: "Argument Error: " do |e|
        "Invalid input: #{e.message}"
      end

      def call
        if type == :handled
          raise ArgumentError, "bad argument"
        elsif type == :unhandled
          raise StandardError, "system failure"
        end
      end
    end

    # Direct ArgumentError with prefix and custom message
    expect(action.call(type: :handled).error).to eq(
      "Argument Error: Invalid input: bad argument",
    )

    # Direct StandardError with prefix only (falls back to exception message)
    expect(action.call(type: :unhandled).error).to eq(
      "System Error: system failure",
    )

    # Nested action with prefix and custom message (requires from: keyword)
    expect(mixed_prefix_action_class.call(type: :nested).error).to eq(
      "Nested: Child failed: that wasn't a nice arg (handled)",
    )
  end

  it "maintains proper message precedence with prefix" do
    action = build_action do
      expects :type

      # General handler with prefix
      error if: StandardError, prefix: "General: "

      # Specific handler with prefix
      error if: ArgumentError, prefix: "Specific: " do |e|
        "Argument issue: #{e.message}"
      end

      def call
        if type == :handled
          raise ArgumentError, "bad input"
        elsif type == :unhandled
          raise StandardError, "general error"
        end
      end
    end

    # ArgumentError should use the specific handler
    expect(action.call(type: :handled).error).to eq(
      "Specific: Argument issue: bad input",
    )

    # StandardError should use the general handler
    expect(action.call(type: :unhandled).error).to eq(
      "General: general error",
    )
  end

  it "supports prefix keyword for success messages" do
    action = build_action do
      expects :type

      # Success with prefix and custom message
      success if: -> { type == :special }, prefix: "Success: " do
        "Special operation completed"
      end

      # Success with prefix only (should work for success messages)
      success if: -> { type == :basic }, prefix: "Success: "

      # Static success with prefix
      success prefix: "Default: " do
        "Operation completed successfully"
      end

      def call
        # Always succeed for this test
      end
    end

    # Test conditional success with custom message
    result = action.call(type: :special)
    expect(result).to be_ok
    expect(result.success).to eq("Success: Special operation completed")

    # Test conditional success with prefix only (should use default success message)
    result = action.call(type: :basic)
    expect(result).to be_ok
    expect(result.success).to eq("Success: Operation completed successfully")

    # Test static success with prefix
    result = action.call(type: :other)
    expect(result).to be_ok
    expect(result.success).to eq("Default: Operation completed successfully")
  end

  it "raises ArgumentError when using from: with success messages" do
    expect do
      stub_const("InvalidSuccessAction", Class.new do
        include Action

        success from: Object, prefix: "Prefix: "
      end)
    end.to raise_error(ArgumentError, "from: only applies to error messages")
  end
end
