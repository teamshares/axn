# frozen_string_literal: true

RSpec.describe "Axn::Mountable inherit modes with module targets" do
  let(:test_module) do
    Module.new do
      def self.included(base)
        base.class_eval do
          include Axn
          before :module_hook
          on_success :module_callback
          error "Module error"
        end
      end

      def module_hook
        # Hook from module
      end

      def module_callback
        # Callback from module
      end

      def module_method
        "from module"
      end
    end
  end

  describe "mount_axn with module target and :lifecycle mode" do
    let(:client_class) do
      mod = test_module
      Class.new do
        include mod

        mount_axn :test_action, inherit: :lifecycle do
          def call
            module_method
          end
        end
      end
    end

    let(:mounted_axn) { client_class::Axns::TestAction }

    it "inherits hooks from the module base class" do
      expect(mounted_axn.before_hooks).not_to be_empty
      expect(mounted_axn.before_hooks).to include(:module_hook)
    end

    it "inherits callbacks from the module base class" do
      expect(mounted_axn._callbacks_registry.for(:success)).not_to be_empty
    end

    it "inherits messages from the module base class" do
      expect(mounted_axn._messages_registry.for(:error)).not_to be_empty
    end

    it "does not inherit fields (as expected with :lifecycle)" do
      expect(mounted_axn.internal_field_configs).to be_empty
    end

    it "can access module methods through inheritance" do
      result = client_class.test_action!
      expect(result).to be_ok
      # The action can successfully call module_method, which proves inheritance works
      # (it would raise NoMethodError if the method wasn't available)
    end
  end

  describe "mount_axn with module target and :none mode" do
    let(:client_class) do
      mod = test_module
      Class.new do
        include mod

        mount_axn :test_action, inherit: :none do
          def call
            "standalone"
          end
        end
      end
    end

    let(:mounted_axn) { client_class::Axns::TestAction }

    it "does not inherit hooks" do
      expect(mounted_axn.before_hooks).to be_empty
    end

    it "does not inherit callbacks" do
      expect(mounted_axn._callbacks_registry.empty?).to be true
    end

    it "does not inherit messages" do
      expect(mounted_axn._messages_registry.empty?).to be true
    end

    it "does not inherit fields" do
      expect(mounted_axn.internal_field_configs).to be_empty
    end
  end

  describe "step with module target and default :none mode" do
    let(:client_class) do
      mod = test_module
      Class.new do
        include mod
        expects :input
        exposes :output

        step :test_step, expects: [:step_input], exposes: [:step_output] do
          expose :step_output, step_input.upcase
        end
      end
    end

    let(:mounted_step) { client_class::Axns::TestStep }

    it "does not inherit hooks (default :none for steps)" do
      expect(mounted_step.before_hooks).to be_empty
    end

    it "does not inherit callbacks" do
      expect(mounted_step._callbacks_registry.empty?).to be true
    end

    it "does not inherit fields from parent" do
      # Should not have :input from parent
      expect(mounted_step.internal_field_configs.map(&:field)).not_to include(:input)
      # Should only have :step_input
      expect(mounted_step.internal_field_configs.map(&:field)).to include(:step_input)
    end
  end
end
