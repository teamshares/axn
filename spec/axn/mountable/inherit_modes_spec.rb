# frozen_string_literal: true

RSpec.describe "Axn::Mountable inherit modes" do
  describe "inherit: :lifecycle" do
    let(:parent_class) do
      Class.new do
        include Axn

        expects :input
        exposes :output

        before :parent_before
        after :parent_after
        on_success :parent_on_success
        error "Parent error"
        success "Parent success"

        def call
          "parent call"
        end

        def parent_before; end
        def parent_after; end
        def parent_on_success; end

        mount_axn :child_action, inherit: :lifecycle do
          def call
            "child call"
          end
        end
      end
    end

    let(:mounted_axn) { parent_class::Axns::ChildAction }

    it "does not inherit fields" do
      expect(mounted_axn.internal_field_configs).to be_empty
      expect(mounted_axn.external_field_configs).to be_empty
    end

    it "inherits hooks" do
      expect(mounted_axn.before_hooks).not_to be_empty
      expect(mounted_axn.after_hooks).not_to be_empty
    end

    it "inherits callbacks" do
      expect(mounted_axn._callbacks_registry.for(:success)).not_to be_empty
    end

    it "inherits messages" do
      expect(mounted_axn._messages_registry.for(:error)).not_to be_empty
      expect(mounted_axn._messages_registry.for(:success)).not_to be_empty
    end
  end

  describe "inherit: :async_only" do
    let(:parent_class) do
      Class.new do
        include Axn

        expects :input
        before :parent_before
        on_success :parent_on_success
        error "Parent error"

        def call
          "parent call"
        end

        def parent_before; end
        def parent_on_success; end

        mount_axn :child_action, inherit: :async_only do
          def call
            "child call"
          end
        end
      end
    end

    let(:mounted_axn) { parent_class::Axns::ChildAction }

    it "does not inherit fields" do
      expect(mounted_axn.internal_field_configs).to be_empty
    end

    it "does not inherit hooks" do
      expect(mounted_axn.before_hooks).to be_empty
    end

    it "does not inherit callbacks" do
      expect(mounted_axn._callbacks_registry.for(:success)).to be_empty
    end

    it "does not inherit messages" do
      expect(mounted_axn._messages_registry.for(:error)).to be_empty
    end
  end

  describe "inherit: :none" do
    let(:parent_class) do
      Class.new do
        include Axn

        expects :input
        before :parent_before

        def call
          "parent call"
        end

        def parent_before; end

        mount_axn :child_action, inherit: :none do
          def call
            "child call"
          end
        end
      end
    end

    let(:mounted_axn) { parent_class::Axns::ChildAction }

    it "does not inherit fields" do
      expect(mounted_axn.internal_field_configs).to be_empty
    end

    it "does not inherit hooks" do
      expect(mounted_axn.before_hooks).to be_empty
    end

    it "does not inherit callbacks" do
      expect(mounted_axn._callbacks_registry.empty?).to be true
    end

    it "does not inherit messages" do
      expect(mounted_axn._messages_registry.empty?).to be true
    end
  end

  describe "inherit: hash with selective inheritance" do
    let(:parent_class) do
      Class.new do
        include Axn

        expects :input
        before :parent_before
        on_success :parent_on_success
        error "Parent error"

        def call
          "parent call"
        end

        def parent_before; end
        def parent_on_success; end

        mount_axn :child_action, inherit: { fields: false, async: false, hooks: false, callbacks: true, messages: false } do
          def call
            "child call"
          end
        end
      end
    end

    let(:mounted_axn) { parent_class::Axns::ChildAction }

    it "respects fields: false" do
      expect(mounted_axn.internal_field_configs).to be_empty
    end

    it "respects hooks: false" do
      expect(mounted_axn.before_hooks).to be_empty
    end

    it "respects callbacks: true" do
      expect(mounted_axn._callbacks_registry.for(:success)).not_to be_empty
    end

    it "respects messages: false" do
      expect(mounted_axn._messages_registry.for(:error)).to be_empty
    end
  end

  describe "default inherit modes for different strategies" do
    it "step defaults to :none" do
      parent = Class.new do
        include Axn
        before :some_hook

        def call; end
        def some_hook; end

        step :my_step do
          def call; end
        end
      end

      mounted_axn = parent::Axns::MyStep
      expect(mounted_axn.before_hooks).to be_empty
    end

    it "mount_axn defaults to :lifecycle" do
      parent = Class.new do
        include Axn
        before :some_hook

        def call; end
        def some_hook; end

        mount_axn :my_action do
          def call; end
        end
      end

      mounted_axn = parent::Axns::MyAction
      # Default behavior (inherit: :lifecycle) means inherit hooks but not fields
      expect(mounted_axn.before_hooks).not_to be_empty
      expect(mounted_axn.internal_field_configs).to be_empty
    end

    it "enqueues_each uses shared EnqueueAllOrchestrator with its own fixed fields" do
      parent = Class.new do
        include Axn
        before :some_hook
        expects :number

        def call; end
        def some_hook; end

        enqueues_each :number, from: -> { [1, 2, 3] }
      end

      # The shared trigger has its own fixed fields, not the parent's
      trigger = Axn::Async::EnqueueAllOrchestrator
      expect(trigger.internal_field_configs.map(&:field)).to contain_exactly(:target_class_name, :static_args)
      expect(trigger.internal_field_configs.map(&:field)).not_to include(:number)

      # Parent still has its expects declarations
      expect(parent.internal_field_configs.map(&:field)).to include(:number)
    end
  end
end
