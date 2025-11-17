# frozen_string_literal: true

# Ensure the strategy is loaded before referencing the constant
Axn::Strategies.built_in

RSpec.describe Axn::Strategies::Form do
  let(:test_action) { build_axn }

  # Simple form object for testing
  let(:form_class) do
    Class.new do
      attr_reader :attributes

      def initialize(attributes = {})
        @attributes = attributes
        @valid = attributes.fetch(:valid, true)
      end

      def valid?
        @valid
      end
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
        expect(instance.form.attributes).to eq({ foo: "bar" })
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
        expect(instance.my_form.attributes).to eq({ foo: "bar" })
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
        action_with_inject.use(:form, type: form_class, inject: %i[user company])
        instance = action_with_inject.allocate
        instance.send(:initialize, params: { foo: "bar" }, user: "Alice", company: "Acme")

        expect(instance.form.attributes).to eq({ foo: "bar", user: "Alice", company: "Acme" })
      end

      it "handles nil inject array" do
        test_action.use(:form, type: form_class, inject: nil)
        instance = test_action.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance.form.attributes).to eq({ foo: "bar" })
      end
    end

    context "with auto-detected form class" do
      # Create a named class with nested Form class to test auto-detection
      # rubocop:disable Lint/ConstantDefinitionInBlock
      module FormStrategyTest
        class TestAction
          include Axn

          class Form
            attr_reader :attributes

            def initialize(attributes = {})
              @attributes = attributes
              @valid = attributes.fetch(:valid, true)
            end

            def valid?
              @valid
            end
          end

          use :form

          def call
            # Action logic
          end
        end
      end
      # rubocop:enable Lint/ConstantDefinitionInBlock

      it "auto-detects form class from action namespace" do
        instance = FormStrategyTest::TestAction.allocate
        instance.send(:initialize, params: { foo: "bar" })

        expect(instance.form).to be_a(FormStrategyTest::TestAction::Form)
        expect(instance.form.attributes).to eq({ foo: "bar" })
      end
    end

    context "validation" do
      it "fails action if form is invalid" do
        invalid_form_class = Class.new do
          attr_reader :attributes

          def initialize(attributes = {})
            @attributes = attributes
          end

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
        memoized_form_class = Class.new do
          attr_reader :attributes, :call_count

          def initialize(attributes = {})
            @attributes = attributes
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
    end

    context "with nil params" do
      it "handles nil params gracefully" do
        test_action.use(:form, type: form_class)
        instance = test_action.allocate
        instance.send(:initialize, params: nil)

        expect(instance.form.attributes).to eq({})
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
