# frozen_string_literal: true

RSpec.describe "inherit_from_target option - simple verification" do
  it "allows steps to inherit from target when explicitly requested" do
    target_class = Class.new do
      include Axn

      def shared_method
        "from_target"
      end
    end

    # Create a step that inherits from target
    target_class.step :test_step,
                      expects: [:step_field],
                      exposes: [:step_output],
                      _inherit_from_target: true do
      # This should work because we inherit from target
      expose :step_output, "Step: #{step_field} - #{shared_method}"
    end

    # The main action needs to declare the fields that steps expose
    target_class.class_eval do
      expects :step_field
      exposes :step_output
    end

    result = target_class.call!(step_field: "test")

    expect(result).to be_ok
    expect(result.step_output).to eq("Step: test - from_target")
  end

  it "defaults steps to inherit from Object" do
    target_class = Class.new do
      include Axn

      def shared_method
        "from_target"
      end
    end

    # Create a step with default behavior (_inherit_from_target: false)
    target_class.step :test_step,
                      expects: [:step_field],
                      exposes: [:step_output] do
      # This should work because we inherit from Object, not target
      expose :step_output, "Step: #{step_field}"
    end

    # The main action needs to declare the fields that steps expose
    target_class.class_eval do
      expects :step_field
      exposes :step_output
    end

    result = target_class.call!(step_field: "test")

    expect(result).to be_ok
    expect(result.step_output).to eq("Step: test")
  end

  it "allows axn actions to inherit from target when explicitly requested" do
    target_class = Class.new do
      include Axn

      def shared_method
        "from_target"
      end
    end

    # Create an axn action that inherits from target
    target_class.mount_axn :test_axn,
                           expects: [:axn_field],
                           exposes: [:axn_output],
                           _inherit_from_target: true do
      expose :axn_output, "Axn: #{axn_field} - #{shared_method}"
    end

    result = target_class.test_axn!(axn_field: "test")

    expect(result).to be_ok
    expect(result.axn_output).to eq("Axn: test - from_target")
  end

  it "allows method actions to inherit from target when explicitly requested" do
    target_class = Class.new do
      include Axn

      def shared_method
        "from_target"
      end
    end

    # Create a method action that inherits from target
    target_class.mount_axn_method :test_method,
                                  expects: [:method_field],
                                  _inherit_from_target: true do
      "Method: #{method_field} - #{shared_method}"
    end

    result = target_class.test_method!(method_field: "test")

    expect(result).to eq("Method: test - from_target")
  end
end
