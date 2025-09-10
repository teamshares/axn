# frozen_string_literal: true

RSpec.describe Axn do
  let(:inner_action_class) do
    stub_const("InnerAction", Class.new do
      include Axn

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
      include Axn

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
      include Axn

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
      include Axn

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
      include Axn

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
        case type
        when :handled
          raise ArgumentError, "bad argument"
        when :unhandled
          raise StandardError, "system failure"
        when :nested
          InnerAction.call!(type: :handled)
        end
      end
    end)
  end

  context "when configured on an action" do
    it "handles handled errors with custom message" do
      expect(outer_action_class.call(type: :handled).error).to eq(
        "PREFIXED: that wasn't a nice arg (handled)",
      )
    end

    it "handles unhandled errors with default message" do
      expect(outer_action_class.call(type: :unhandled).error).to eq(
        "PREFIXED: default inner error",
      )
    end
  end

  context "with prefix keyword for error messages" do
    let(:action) do
      build_axn do
        expects :type

        error if: StandardError, prefix: "Baz: "
        error if: ArgumentError, prefix: "Foo: " do |_e|
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
    end

    it "handles ArgumentError with custom message and prefix" do
      expect(action.call(type: :handled).error).to eq("Foo: bar")
    end

    it "handles StandardError with prefix only" do
      expect(action.call(type: :unhandled).error).to eq("Baz: unhandled")
    end
  end

  context "combining prefix with from keyword" do
    it "handles handled errors with custom message" do
      expect(prefix_with_from_action_class.call(type: :handled).error).to eq(
        "Outer: wrapped: that wasn't a nice arg (handled)",
      )
    end

    it "handles unhandled errors with default message" do
      expect(prefix_with_from_action_class.call(type: :unhandled).error).to eq(
        "Outer: wrapped: default inner error",
      )
    end
  end

  context "combining prefix with from keyword (prefix only)" do
    it "handles handled errors with prefix only" do
      expect(prefix_only_from_action_class.call(type: :handled).error).to eq(
        "Outer: that wasn't a nice arg (handled)",
      )
    end

    it "handles unhandled errors with prefix only" do
      expect(prefix_only_from_action_class.call(type: :unhandled).error).to eq(
        "Outer: default inner error",
      )
    end
  end

  context "with mixed prefix scenarios" do
    let(:action) do
      build_axn do
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
    end

    it "handles ArgumentError with prefix and custom message" do
      expect(action.call(type: :handled).error).to eq(
        "Argument Error: Invalid input: bad argument",
      )
    end

    it "handles StandardError with prefix only" do
      expect(action.call(type: :unhandled).error).to eq(
        "System Error: system failure",
      )
    end

    it "handles nested action with prefix and custom message" do
      expect(mixed_prefix_action_class.call(type: :nested).error).to eq(
        "Nested: Child failed: that wasn't a nice arg (handled)",
      )
    end
  end

  context "maintaining proper message precedence with prefix" do
    let(:action) do
      build_axn do
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
    end

    it "uses specific handler for ArgumentError" do
      expect(action.call(type: :handled).error).to eq(
        "Specific: Argument issue: bad input",
      )
    end

    it "uses general handler for StandardError" do
      expect(action.call(type: :unhandled).error).to eq(
        "General: general error",
      )
    end
  end

  context "with prefix keyword for success messages" do
    let(:action) do
      build_axn do
        expects :type

        # Static success with prefix
        success prefix: "Default: " do
          "Operation completed successfully"
        end

        # Success with prefix and custom message
        success if: -> { type == :different }, prefix: "Success: " do
          "Special operation completed"
        end

        # Success with prefix only (should work for success messages)
        success if: -> { type == :basic }, prefix: "Success: "
      end
    end

    let(:string_action) do
      build_axn do
        expects :type

        # Static success with prefix and string message
        success "Operation completed successfully", prefix: "Default: "

        # Success with prefix only (should work for success messages)
        success if: -> { type == :basic }, prefix: "Success: "
      end
    end

    it "handles conditional success with custom message" do
      result = action.call(type: :different)
      expect(result).to be_ok
      expect(result.success).to eq("Success: Special operation completed")
    end

    it "handles conditional success with prefix only" do
      result = action.call(type: :basic)
      expect(result).to be_ok
      # The prefix-only message should find content from the static handler since conditional doesn't match
      expect(result.success).to eq("Success: Operation completed successfully")
    end

    it "handles static success with prefix" do
      result = action.call(type: :other)
      expect(result).to be_ok
      expect(result.success).to eq("Default: Operation completed successfully")
    end

    it "handles conditional success with prefix only using static string message" do
      result = string_action.call(type: :basic)
      expect(result).to be_ok
      expect(result.success).to eq("Success: Operation completed successfully")
    end
  end

  context "combining from: with if: keyword" do
    it "raises ArgumentError when using from: with if:" do
      expect do
        stub_const("InvalidFromIfAction", Class.new do
          include Axn
          error "Invalid combination", from: Object, if: StandardError
        end)
      end.to raise_error(Axn::UnsupportedArgument,
                         "Combining from: with if: or unless: is not currently supported.\n\n" \
                         "Implementation is technically possible but very complex. Please submit a " \
                         "Github Issue if you have a real-world need for this functionality.")
    end

    it "raises ArgumentError when using from: with unless:" do
      expect do
        stub_const("InvalidFromUnlessAction", Class.new do
          include Axn
          error "Invalid combination", from: Object, unless: StandardError
        end)
      end.to raise_error(Axn::UnsupportedArgument,
                         "Combining from: with if: or unless: is not currently supported.\n\n" \
                         "Implementation is technically possible but very complex. Please submit a " \
                         "Github Issue if you have a real-world need for this functionality.")
    end
  end

  it "raises ArgumentError when using from: with success messages" do
    expect do
      stub_const("InvalidSuccessAction", Class.new do
        include Axn

        success from: Object, prefix: "Prefix: "
      end)
    end.to raise_error(ArgumentError, "from: only applies to error messages")
  end

  context "with callable prefixes" do
    let(:callable_prefix_action_class) do
      Class.new do
        include Axn

        expects :type

        # String prefix (backward compatibility)
        error if: -> { type == :string }, prefix: "String: " do
          "string error"
        end

        # Symbol prefix
        error if: -> { type == :symbol }, prefix: :prefix_method do
          "symbol error"
        end

        # Block prefix
        error if: -> { type == :block }, prefix: -> { "Block: " } do
          "block error"
        end

        # Block prefix with exception
        error if: -> { type == :exception }, prefix: ->(exception:) { "Exception #{exception.class}: " } do
          "exception error"
        end

        # Block prefix with positional exception
        error if: -> { type == :positional }, prefix: ->(exception) { "Positional #{exception.class}: " } do
          "positional error"
        end

        # Block prefix with no args
        error if: -> { type == :no_args }, prefix: -> { "No args: " } do
          "no args error"
        end

        def call
          case type
          when :string
            raise ArgumentError, "string error"
          when :symbol
            raise ArgumentError, "symbol error"
          when :block
            raise ArgumentError, "block error"
          when :exception
            raise ArgumentError, "exception error"
          when :positional
            raise ArgumentError, "positional error"
          when :no_args
            raise ArgumentError, "no args error"
          end
        end

        private

        def prefix_method
          "Symbol: "
        end
      end
    end

    it "handles string prefixes (backward compatibility)" do
      result = callable_prefix_action_class.call(type: :string)
      expect(result.error).to eq("String: string error")
    end

    it "handles symbol prefixes" do
      result = callable_prefix_action_class.call(type: :symbol)
      expect(result.error).to eq("Symbol: symbol error")
    end

    it "handles block prefixes" do
      result = callable_prefix_action_class.call(type: :block)
      expect(result.error).to eq("Block: block error")
    end

    it "handles block prefixes with exception keyword" do
      result = callable_prefix_action_class.call(type: :exception)
      expect(result.error).to eq("Exception ArgumentError: exception error")
    end

    it "handles block prefixes with positional exception" do
      result = callable_prefix_action_class.call(type: :positional)
      expect(result.error).to eq("Positional ArgumentError: positional error")
    end

    it "handles block prefixes with no arguments" do
      result = callable_prefix_action_class.call(type: :no_args)
      expect(result.error).to eq("No args: no args error")
    end
  end

  context "with callable prefixes and exception messages" do
    let(:callable_prefix_exception_action_class) do
      Class.new do
        include Axn

        expects :type

        # Symbol prefix with exception message fallback
        error if: -> { type == :symbol }, prefix: :prefix_method

        # Block prefix with exception message fallback
        error if: -> { type == :block }, prefix: -> { "Block: " }

        # Block prefix with exception keyword and exception message fallback
        error if: -> { type == :exception }, prefix: ->(exception:) { "Exception #{exception.class}: " }

        def call
          case type
          when :symbol, :block, :exception
            raise StandardError, "test exception"
          end
        end

        private

        def prefix_method
          "Symbol: "
        end
      end
    end

    it "handles symbol prefixes with exception messages" do
      result = callable_prefix_exception_action_class.call(type: :symbol)
      expect(result.error).to eq("Symbol: test exception")
    end

    it "handles block prefixes with exception messages" do
      result = callable_prefix_exception_action_class.call(type: :block)
      expect(result.error).to eq("Block: test exception")
    end

    it "handles block prefixes with exception keyword and exception messages" do
      result = callable_prefix_exception_action_class.call(type: :exception)
      expect(result.error).to eq("Exception StandardError: test exception")
    end
  end
end
