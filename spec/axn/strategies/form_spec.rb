# frozen_string_literal: true

# Ensure the strategy is loaded before referencing the constant
Axn::Strategies.built_in

RSpec.describe Axn::Strategies::Form do
  let(:test_action) { build_axn }

  let(:form_class) do
    Class.new(Axn::FormObject) do
      attr_accessor :foo
    end
  end

  describe ".configure" do
    context "with default configuration" do
      it "creates a form method with default name" do
        test_action.use(:form, type: form_class)
        instance = test_action.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance).to respond_to(:form)
        expect(instance.form).to be_a(form_class)
        expect(instance.form.foo).to eq("bar")
      end

      it "expects params and exposes form" do
        test_action.use(:form, type: form_class)
        instance = test_action.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance.params).to eq({ foo: "bar" })
        expect(instance.form).to be_a(form_class)
      end
    end

    context "with custom expect and expose names" do
      it "uses custom attribute names" do
        test_action.use(:form, expect: :input, expose: :my_form, type: form_class)
        instance = test_action.allocate
        instance.send(:initialize, input: { foo: "bar" })

        expect(instance).to respond_to(:my_form)
        expect(instance).not_to respond_to(:form)
        expect(instance.my_form).to be_a(form_class)
        expect(instance.my_form.foo).to eq("bar")
      end
    end

    context "with inject option" do
      let(:action_with_inject) do
        build_axn do
          expects :user
          expects :company
        end
      end

      it "injects additional context attributes into form" do
        inject_form_class = Class.new(Axn::FormObject) do
          attr_accessor :foo, :user, :company
        end

        action_with_inject.use(:form, type: inject_form_class, inject: %i[user company])
        instance = action_with_inject.allocate
        instance.send(:initialize, params: { foo: "bar" }, user: "Alice", company: "Acme")

        expect(instance.form.to_h).to eq({ foo: "bar", user: "Alice", company: "Acme" })
      end

      it "handles nil inject array" do
        test_action.use(:form, type: form_class, inject: nil)
        instance = test_action.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance.form.foo).to eq("bar")
      end
    end

    context "with auto-detected form class" do
      let(:form_class) do
        Class.new(Axn::FormObject) do
          attr_accessor :foo
        end
      end

      let(:test_action_class) do
        Class.new do
          include Axn

          def call
            # Action logic
          end
        end
      end

      before do
        stub_const("FormStrategyTest", Module.new)
        stub_const("FormStrategyTest::TestAction", test_action_class)
        stub_const("FormStrategyTest::TestAction::Form", form_class)
        FormStrategyTest::TestAction.class_eval { use :form }
      end

      it "auto-detects form class from action namespace" do
        instance = FormStrategyTest::TestAction.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance.form).to be_a(FormStrategyTest::TestAction::Form)
        expect(instance.form.foo).to eq("bar")
      end
    end

    context "validation" do
      it "fails action if form is invalid" do
        invalid_form_class = Class.new(Axn::FormObject) do
          attr_accessor :foo

          def valid?
            false
          end
        end

        test_action.use(:form, type: invalid_form_class)
        result = test_action.call(params: { foo: "bar" })

        expect(result).not_to be_ok
      end

      it "succeeds if form is valid" do
        test_action.use(:form, type: form_class)
        result = test_action.call(params: { foo: "bar" })

        expect(result).to be_ok
      end
    end

    context "memoization" do
      it "memoizes the form instance" do
        memoized_form_class = Class.new(Axn::FormObject) do
          attr_accessor :foo

          def initialize(attributes = {})
            super
            @call_count = 0
          end

          def valid?
            @call_count += 1
            true
          end
        end

        test_action.use(:form, type: memoized_form_class)
        instance = test_action.allocate
        instance.send(:initialize, params: { foo: "bar" })

        # Access form multiple times
        form1 = instance.form
        form2 = instance.form

        expect(form1).to be(form2)
      end
    end

    context "with block-based form definition" do
      let(:create_user_class) { build_axn }

      before do
        stub_const("BlockFormTest", Module.new)
        stub_const("BlockFormTest::CreateUser", create_user_class)
        BlockFormTest::CreateUser.class_eval do
          use :form, type: "BlockFormTest::CreateUser::Form" do
            validates :name, :email, presence: true
          end
        end
      end

      it "defines form class inline when type constant doesn't exist" do
        instance = BlockFormTest::CreateUser.allocate
        instance.send(:initialize, params: { name: "Alice", email: "alice@example.com" })

        expect(instance.form).to be_a(BlockFormTest::CreateUser::Form)
        expect(BlockFormTest::CreateUser::Form < Axn::FormObject).to be(true)
        expect(instance.form.to_h).to eq({ name: "Alice", email: "alice@example.com" })
        expect(instance.form.email).to eq("alice@example.com")
        expect(instance.form.valid?).to be(true)
      end

      it "evaluates block in the context of the class" do
        # Verify that self inside the block was the class
        form_instance = BlockFormTest::CreateUser::Form.new(name: "Test", email: "test@example.com")
        expect(form_instance).to respond_to(:name)
        expect(form_instance).to respond_to(:email)
        expect(form_instance).to respond_to(:valid?)
      end

      it "works with nested namespaces" do
        stub_const("BlockFormTest::Nested", Module.new)

        nested_action_class = Class.new do
          include Axn
        end

        stub_const("BlockFormTest::Nested::Action", nested_action_class)
        BlockFormTest::Nested::Action.class_eval do
          use :form, type: "BlockFormTest::Nested::Action::Form" do
            attr_accessor :value
          end
        end

        instance = BlockFormTest::Nested::Action.allocate
        instance.send(:initialize, params: { value: "test" })

        expect(instance.form).to be_a(BlockFormTest::Nested::Action::Form)
        expect(instance.form.value).to eq("test")
      end
    end

    context "error handling" do
      it "raises error if type is nil for anonymous class" do
        anonymous_action = Class.new do
          include Axn
        end

        expect do
          anonymous_action.use(:form, type: nil)
        end.to raise_error(ArgumentError, "form strategy: must pass explicit :type parameter to `use :form` when applying to anonymous classes")
      end

      it "raises error if form class does not implement valid?" do
        invalid_form_class = Class.new do
          def initialize(_attributes = {}); end
        end

        expect do
          test_action.use(:form, type: invalid_form_class)
        end.to raise_error(ArgumentError, "form strategy: #{invalid_form_class} must implement `valid?`")
      end

      let(:existing_form_class) do
        Class.new(Axn::FormObject) do
          attr_accessor :foo
        end
      end

      let(:error_test_action_class) { build_axn }

      before do
        stub_const("ErrorTest", Module.new)
        stub_const("ErrorTest::ExistingForm", existing_form_class)
        stub_const("ErrorTest::Action", error_test_action_class)
      end

      it "raises error if type constant exists and block is provided" do
        expect do
          ErrorTest::Action.use(:form, type: "ErrorTest::ExistingForm") do
            # This should not be evaluated
          end
        end.to raise_error(ArgumentError, "form strategy: cannot provide block when type constant ErrorTest::ExistingForm already exists")
      end

      it "raises error if type constant doesn't exist and no block is provided" do
        action = build_axn

        expect do
          action.use(:form, type: "NonExistent::Form")
        end.to raise_error(ArgumentError, "form strategy: type constant NonExistent::Form does not exist and no block provided to define it")
      end

      it "raises error if type is a Class and block is provided" do
        expect do
          test_action.use(:form, type: form_class) do
            # This should not be evaluated
          end
        end.to raise_error(ArgumentError, "form strategy: cannot provide block when type is a Class")
      end
    end

    context "with nil params" do
      it "handles nil params gracefully" do
        test_action.use(:form, type: form_class)
        instance = test_action.allocate
        instance.send(:initialize, params: nil)

        expect(instance.form).to be_a(form_class)
        expect(instance.form.foo).to be_nil
        expect(instance.form.to_h).to eq({ foo: nil })
      end
    end
  end

  describe "strategy registration" do
    it "is automatically loaded as a built-in strategy" do
      expect(Axn::Strategies.built_in[:form]).to be(described_class)
    end

    it "can be used via use method" do
      test_action.use(:form, type: form_class)
      instance = test_action.allocate
      instance.send(:initialize, params: { foo: "bar" })

      expect(instance).to respond_to(:form)
    end
  end
end
