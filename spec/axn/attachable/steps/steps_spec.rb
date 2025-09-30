# frozen_string_literal: true

RSpec.describe "Step functionality" do
  describe "basic step functionality" do
    it "executes a simple step" do
      action = build_axn do
        expects :input
        exposes :output

        step :process, expects: [:input], exposes: [:output] do
          expose :output, "Processed: #{input}"
        end
      end

      result = action.call!(input: "test")

      expect(result).to be_ok
      expect(result.output).to eq("Processed: test")
    end

    it "executes multiple steps sequentially" do
      action = build_axn do
        expects :input
        exposes :final_output

        step :step1, expects: [:input], exposes: [:intermediate] do
          expose :intermediate, input.upcase
        end

        step :step2, expects: [:intermediate], exposes: [:final_output] do
          expose :final_output, "Final: #{intermediate}"
        end
      end

      result = action.call!(input: "hello")

      expect(result).to be_ok
      expect(result.final_output).to eq("Final: HELLO")
    end
  end

  describe "data flow between steps" do
    it "transforms data through steps" do
      action = build_axn do
        expects :input
        exposes :output

        step :transform, expects: [:input], exposes: [:output] do
          expose :output, "Transformed: #{input}"
        end
      end

      result = action.call!(input: "test")

      expect(result).to be_ok
      expect(result.output).to eq("Transformed: test")
    end
  end

  describe "step error handling" do
    it "handles step failures gracefully" do
      action = build_axn do
        expects :input
        exposes :output

        step :validate, expects: [:input], exposes: [:output] do
          fail! "Input too short" if input.length < 3
          expose :output, "Valid"
        end
      end

      result = action.call(input: "ab")

      expect(result).not_to be_ok
      expect(result.error).to eq("validate: Input too short")
    end

    it "uses custom error_prefix when provided" do
      action = build_axn do
        expects :input
        exposes :output

        step :validate, error_prefix: "Validation failed - ", expects: [:input], exposes: [:output] do
          fail! "Input too short" if input.length < 3
          expose :output, "Valid"
        end
      end

      result = action.call(input: "ab")

      expect(result).not_to be_ok
      expect(result.error).to eq("Validation failed - Input too short")
    end

    it "defaults to step name with colon when no error_prefix provided" do
      action = build_axn do
        expects :input
        exposes :output

        step :custom_name, expects: [:input], exposes: [:output] do
          fail! "Something went wrong"
        end
      end

      result = action.call(input: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("custom_name: Something went wrong")
    end
  end

  describe "steps without labels" do
    it "defaults to 'Step N' prefix when step fails and no label is provided" do
      # Create action classes separately using build_axn
      first_step = build_axn do
        expects :input
        exposes :intermediate

        def call
          fail! "First step failed"
        end
      end

      second_step = build_axn do
        expects :intermediate
        exposes :output

        def call
          fail! "Second step failed"
        end
      end

      action = build_axn do
        expects :input
        exposes :output

        # Add steps using the steps method (which creates entries without labels)
        steps(first_step, second_step)
      end

      result = action.call(input: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("Step 1: First step failed")
    end

    it "uses sequential numbering for multiple steps without labels" do
      # Create action classes separately using build_axn
      first_step = build_axn do
        expects :input
        exposes :intermediate

        def call
          expose :intermediate, "success"
        end
      end

      second_step = build_axn do
        expects :intermediate
        exposes :output

        def call
          fail! "Second step failed"
        end
      end

      action = build_axn do
        expects :input
        exposes :output

        steps(first_step, second_step)
      end

      result = action.call(input: "test")

      expect(result).not_to be_ok
      expect(result.error).to eq("Step 2: Second step failed")
    end
  end

  describe "using existing action classes" do
    it "composes multiple action classes as steps" do
      # Create reusable action classes
      upcase_action = build_axn do
        expects :text
        exposes :uppercased

        def call
          expose :uppercased, text.upcase
        end
      end

      format_action = build_axn do
        expects :uppercased
        exposes :formatted

        def call
          expose :formatted, "Result: #{uppercased}"
        end
      end

      # Compose them as steps
      composed_action = build_axn do
        expects :text
        exposes :uppercased, :formatted

        steps(upcase_action, format_action)
      end

      result = composed_action.call!(text: "hello")

      expect(result).to be_ok
      expect(result.uppercased).to eq("HELLO")
      expect(result.formatted).to eq("Result: HELLO")
    end
  end

  describe "mixed step approaches" do
    it "combines existing actions with inline steps" do
      # Create a reusable action
      validate_action = build_axn do
        expects :email
        exposes :validated_email

        def call
          fail! "Invalid email" unless email.include?("@")
          expose :validated_email, email.downcase
        end
      end

      # Use it alongside inline steps
      action = build_axn do
        expects :email
        exposes :validated_email, :welcome_message

        steps(validate_action)

        step :create_welcome, expects: [:validated_email], exposes: [:welcome_message] do
          expose :welcome_message, "Welcome #{validated_email}!"
        end
      end

      result = action.call!(email: "USER@EXAMPLE.COM")

      expect(result).to be_ok
      expect(result.validated_email).to eq("user@example.com")
      expect(result.welcome_message).to eq("Welcome user@example.com!")
    end
  end

  describe "expose_return_as shorthand" do
    it "directly exposes return values" do
      action = build_axn do
        expects :value
        exposes :doubled

        step :double_it, expects: [:value], expose_return_as: :doubled do
          value * 2
        end
      end

      result = action.call!(value: 21)

      expect(result).to be_ok
      expect(result.doubled).to eq(42)
    end
  end
end
