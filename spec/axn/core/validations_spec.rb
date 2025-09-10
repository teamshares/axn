# frozen_string_literal: true

RSpec.describe Axn do
  describe "inbound validation" do
    let(:action) do
      build_axn do
        expects :foo, type: Numeric, numericality: { greater_than: 10 }
      end
    end

    context "success" do
      subject { action.call(foo: 11, bar: 5, baz: 1) }

      it { is_expected.to be_ok }
    end

    context "contract failure" do
      subject { action.call(foo: 9, bar: 5, baz: 1) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo must be greater than 10")
      end
    end

    context "with missing inbound args" do
      subject { action.call(bar: 12, baz: 13) }

      it "fails inbound" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
      end
    end

    context "with outbound missing" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, numericality: { greater_than: 10 }
          exposes :bar
        end
      end

      subject { action.call(foo: 11, baz: 13) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::OutboundValidationError)
      end
    end

    context "allow_blank is passed to further validators as well" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, numericality: { greater_than: 10 }, allow_blank: true
          exposes :bar, allow_blank: true
        end
      end

      subject { action.call(baz: 13) }

      it { is_expected.to be_ok }
    end

    context "inbound defaults" do
      let(:action) do
        build_axn do
          expects :foo, type: Numeric, default: 99
          exposes :foo
        end
      end

      context "when field is missing" do
        subject { action.call }

        it "applies default" do
          is_expected.to be_ok
          expect(subject.foo).to eq 99
        end
      end

      context "when field is explicitly nil" do
        subject { action.call(foo: nil) }

        it "applies default" do
          is_expected.to be_ok
          expect(subject.foo).to eq 99
        end
      end

      context "when field has a value" do
        subject { action.call(foo: 42) }

        it "preserves existing value" do
          is_expected.to be_ok
          expect(subject.foo).to eq 42
        end
      end
    end

    context "multiple fields validations per call" do
      let(:action) do
        build_axn do
          expects :foo, :bar, type: { with: Numeric, message: "should numberz" }
        end
      end

      context "when one invalid" do
        subject { action.call(foo: 1, bar: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Bar should numberz")
        end
      end

      context "when set" do
        subject { action.call(foo: 1, bar: 2) }

        it { is_expected.to be_ok }
      end
    end

    context "with multiple fields per expects line" do
      let(:action) do
        build_axn do
          expects :foo, :bar, type: Numeric
        end
      end

      context "when valid" do
        subject { action.call(foo: 1, bar: 2) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(foo: 1, bar: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Bar is not a Numeric")
        end
      end
    end

    context "with multiple expectations on the same field" do
      let(:action) do
        build_axn do
          expects :foo, type: String
          expects :foo, numericality: { greater_than: 10 }
        end
      end

      it "raises" do
        expect { action.call(foo: 100) }.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
      end
    end
  end

  describe "outbound validation" do
    let(:action) do
      build_axn do
        exposes :bar, type: Numeric, numericality: { greater_than: 10 }
        exposes :qux, type: Numeric

        def call
          expose :qux, 99
        end
      end
    end

    context "success" do
      subject(:result) { action.call(foo: 10, bar: 11, baz: 1) }

      it { is_expected.to be_ok }

      it "exposes existing context" do
        expect(subject.bar).to eq(11)
      end

      it "exposes new values" do
        expect(subject.qux).to eq(99)
      end

      it "prevents external access of non-exposed values" do
        expect { result.foo }.to raise_error(Axn::ContractViolation::MethodNotAllowed)
      end
    end

    context "contract failure" do
      subject { action.call(foo: 10, bar: 9, baz: 1) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::OutboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Bar must be greater than 10")
      end
    end

    context "setting failure" do
      subject { action.call(foo: 10, bar: 11, baz: 1) }

      let(:action) do
        build_axn do
          exposes :bar, type: Numeric, numericality: { greater_than: 10 }

          def call
            expose :qux, 99
          end
        end
      end

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::ContractViolation::UnknownExposure)
      end
    end

    context "outbound defaults" do
      let(:action) do
        build_axn do
          exposes :foo, default: 99
        end
      end

      subject { action.call }

      it "are set correctly" do
        is_expected.to be_ok
        expect(subject.foo).to eq 99
      end
    end

    context "support optional outbound exposures" do
      let(:action) do
        build_axn do
          expects :foo, type: :boolean
          exposes :bar, allow_blank: true

          def call
            expose :bar, 99 if foo
          end
        end
      end

      context "when not set" do
        subject { action.call(foo: false) }

        it { is_expected.to be_ok }
      end

      context "when set" do
        subject { action.call(foo: true) }

        it { is_expected.to be_ok }
      end
    end

    context "with multiple fields per exposes line" do
      let(:action) do
        build_axn do
          expects :baz
          exposes :foo, :bar, type: Numeric

          def call
            expose foo: baz, bar: baz
          end
        end
      end

      context "when valid" do
        subject { action.call(baz: 100) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(baz: "string") }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::OutboundValidationError)
          expect(subject.exception.message).to eq("Foo is not a Numeric and Bar is not a Numeric")
        end
      end
    end

    context "with multiple expectations on the same field" do
      let(:action) do
        build_axn do
          exposes :foo, type: String
          exposes :foo, numericality: { greater_than: 10 }
        end
      end

      it "raises" do
        expect { action.call(baz: 100) }.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
      end
    end

    context "is accessible on internal context" do
      let(:action) do
        build_axn do
          exposes :foo, default: "bar"

          def call
            puts "Foo is: #{foo}"
          end
        end
      end

      subject { action.call }

      it "is accessible" do
        # TODO: if we apply defaults earlier, this would say bar
        expect { subject }.to output("Foo is: \n").to_stdout
        expect(subject).to be_ok
      end
    end

    context "with default that is a callable" do
      let(:action) do
        build_axn do
          exposes :foo, default: -> { "bar #{helper_method}" }

          private

          def helper_method = 123
        end
      end

      subject { action.call }

      it "has access to local helper methods" do
        expect(subject.foo).to eq "bar 123"
      end
    end

    describe "#expose" do
      let(:action) do
        build_axn do
          exposes :qux

          def call
            expose :qux, 11 # Just confirming can call twice
            expose :qux, 99
          end
        end
      end

      subject { action.call }

      it "can expose" do
        is_expected.to be_ok
        expect(subject.qux).to eq 99
      end
    end
  end

  describe "complex validation" do
    let(:action) do
      build_axn do
        expects :foo, type: String
        exposes :bar, type: String
      end
    end

    context "success" do
      subject { action.call(foo: "a", bar: "b", baz: "c") }

      it { is_expected.to be_ok }
    end

    context "failure" do
      subject { action.call(foo: 1, bar: 2, baz: 3) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.errors).to be_a(ActiveModel::Errors)
        expect(subject.exception.message).to eq("Foo is not a String")
      end
    end
  end

  describe "type" do
    describe "boolean" do
      let(:action) do
        build_axn do
          expects :foo, type: :boolean
        end
      end

      it "validates" do
        expect(action.call(foo: true)).to be_ok
        expect(action.call(foo: false)).to be_ok

        expect(action.call(foo: nil)).not_to be_ok
        expect(action.call(foo: "")).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end

      context "and allow_blank" do
        let(:action) do
          build_axn do
            expects :foo, type: :boolean, allow_blank: true
          end
        end

        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).to be_ok
          expect(action.call(foo: "")).to be_ok
          expect(action.call(foo: 1)).not_to be_ok
        end
      end

      context "and allow_nil" do
        let(:action) do
          build_axn do
            expects :foo, type: :boolean, allow_nil: true
          end
        end

        it "validates" do
          expect(action.call(foo: true)).to be_ok
          expect(action.call(foo: false)).to be_ok

          expect(action.call(foo: nil)).to be_ok
          expect(action.call(foo: 1)).not_to be_ok
          expect(action.call(foo: "")).not_to be_ok
        end
      end

      context "explicit presence settings override implicit validation" do
        let(:action) do
          build_axn do
            expects :foo, type: :boolean
          end
        end

        context "when false" do
          subject { action.call(foo: false) }

          it { is_expected.to be_ok }
        end

        context "when nil" do
          subject { action.call(foo: nil) }

          it "fails" do
            expect(subject).not_to be_ok
            expect(subject.exception).to be_a(Axn::InboundValidationError)
            expect(subject.exception.message).to eq("Foo is not a boolean")
          end
        end
      end

      context "boolean defaults with explicit false values" do
        context "default: false should not override explicit false" do
          let(:action) do
            build_axn do
              expects :is_retirement_age, :has_tenure, type: :boolean, default: false
              exposes :is_retirement_age, :has_tenure, type: :boolean

              def call
                expose :is_retirement_age, is_retirement_age
                expose :has_tenure, has_tenure
              end
            end
          end

          it "preserves explicit false values" do
            result = action.call(is_retirement_age: false, has_tenure: false)

            expect(result).to be_ok
            expect(result.is_retirement_age).to be false
            expect(result.has_tenure).to be false
          end

          it "applies defaults when not provided" do
            result = action.call

            expect(result).to be_ok
            expect(result.is_retirement_age).to be false
            expect(result.has_tenure).to be false
          end

          it "preserves explicit true values" do
            result = action.call(is_retirement_age: true, has_tenure: true)

            expect(result).to be_ok
            expect(result.is_retirement_age).to be true
            expect(result.has_tenure).to be true
          end
        end

        context "default: true should not override explicit false" do
          let(:action) do
            build_axn do
              expects :is_enabled, type: :boolean, default: true
              exposes :is_enabled, type: :boolean

              def call
                expose :is_enabled, is_enabled
              end
            end
          end

          it "preserves explicit false values" do
            result = action.call(is_enabled: false)

            expect(result).to be_ok
            expect(result.is_enabled).to be false
          end

          it "applies default when not provided" do
            result = action.call

            expect(result).to be_ok
            expect(result.is_enabled).to be true
          end

          it "preserves explicit true values" do
            result = action.call(is_enabled: true)

            expect(result).to be_ok
            expect(result.is_enabled).to be true
          end
        end
      end
    end

    describe "array of types" do
      let(:action) do
        build_axn do
          expects :foo, type: [String, Numeric]
        end
      end

      context "when valid" do
        subject { action.call(foo: 123) }

        it { is_expected.to be_ok }
      end

      context "when invalid" do
        subject { action.call(foo: Object.new) }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Foo is not one of String, Numeric")
        end
      end

      context "when false" do
        subject { action.call(foo: false) }

        it "fails" do
          expect(subject).not_to be_ok
          expect(subject.exception).to be_a(Axn::InboundValidationError)
          expect(subject.exception.message).to eq("Foo can't be blank")
        end
      end
    end

    describe "uuid" do
      let(:action) do
        build_axn do
          expects :foo, type: :uuid
        end
      end

      it "validates" do
        expect(action.call(foo: "123e4567-e89b-12d3-a456-426614174000")).to be_ok
        expect(action.call(foo: "123e4567e89b12d3a456426614174000")).to be_ok

        expect(action.call(foo: nil)).not_to be_ok
        expect(action.call(foo: "")).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
        expect(action.call(foo: "abcabc")).not_to be_ok
      end
    end

    describe "params" do
      let(:action) do
        build_axn do
          expects :foo, type: :params
        end
      end

      it "validates" do
        expect(action.call(foo: {})).to be_ok
        expect(action.call(foo: { key: "value" })).to be_ok

        expect(action.call(foo: nil)).not_to be_ok
        expect(action.call(foo: "")).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
        expect(action.call(foo: [])).not_to be_ok
      end

      context "with ActionController::Parameters" do
        before do
          # Create a mock ActionController::Parameters class if not defined
          unless defined?(ActionController::Parameters)
            stub_const("ActionController::Parameters", Class.new(Hash) do
              def initialize(params = {})
                super()
                merge!(params)
              end
            end)
          end
        end

        it "validates ActionController::Parameters" do
          params = ActionController::Parameters.new(key: "value")
          expect(action.call(foo: params)).to be_ok
        end
      end
    end
  end

  describe "preprocessing" do
    let(:action) do
      build_axn do
        expects :date_as_date, type: Date, preprocess: ->(raw) { Date.parse(raw) }
        exposes :date_as_date

        def call
          expose date_as_date:
        end
      end
    end

    context "when preprocessing is successful" do
      subject { action.call(date_as_date: "2020-01-01") }

      it "modifies the context" do
        is_expected.to be_ok
        expect(subject.date_as_date).to be_a(Date)
      end
    end

    context "when preprocessing fails" do
      subject { action.call(date_as_date: "") }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::ContractViolation::PreprocessingError)
      end

      it "sets the cause to the original exception" do
        expect(subject.exception.cause).to be_a(ArgumentError)
        expect(subject.exception.cause.message).to include("invalid date")
      end
    end
  end

  describe "custom validations" do
    let(:action) do
      build_axn do
        expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
      end
    end

    context "when valid" do
      subject { action.call(foo: 20) }

      it { is_expected.to be_ok }
    end

    context "when invalid" do
      subject { action.call(foo: 10) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo must be pretty big")
      end
    end

    context "when validator raises" do
      let(:action) do
        build_axn do
          expects :foo, validate: ->(_value) { raise "oops" }
        end
      end

      subject { action.call(foo: 20) }

      it "fails" do
        expect(subject).not_to be_ok
        expect(subject.exception).to be_a(Axn::InboundValidationError)
        expect(subject.exception.message).to eq("Foo failed validation: oops")
      end
    end
  end

  describe "model" do
    context "top level" do
      context "when field does not end in _id" do
        let(:action) do
          build_axn do
            expects :user, model: true
          end
        end

        it "raises an error" do
          expect { action }.to raise_error(ArgumentError, "Model validation expects to be given a field ending in _id (given: user)")
        end
      end

      let(:action) do
        build_axn do
          expects :user_id, model: true
          exposes :the_user, :user_id

          def call
            expose :user_id, user_id
            expose :the_user, user
          end
        end
      end

      let(:test_model) { double("User", is_a?: true, name: "User") }

      before do
        stub_const("User", test_model)

        allow(test_model).to receive(:find_by).and_return(nil)
        allow(test_model).to receive(:find_by).with(id: 1).and_return(double("User", present?: true))
      end

      it "exposes readers" do
        result = action.call(user_id: 1)
        expect(result).to be_ok
        expect(result.the_user.inspect).to eq(test_model.inspect)
        expect(result.user_id).to eq(1)
      end

      it "validates" do
        expect(action.call(user_id: nil)).not_to be_ok
        expect(action.call(user_id: 2)).not_to be_ok
      end
    end

    context "subfield" do
      context "when field does not end in _id" do
        let(:action) do
          build_axn do
            expects :foo
            expects :user, model: true, on: :foo
          end
        end

        it "raises an error" do
          expect { action }.to raise_error(ArgumentError, "Model validation expects to be given a field ending in _id (given: user)")
        end
      end

      let(:action) do
        build_axn do
          expects :foo
          expects :user_id, model: true, on: :foo
          exposes :the_user, :user_id

          def call
            expose :user_id, foo[:user_id]
            expose :the_user, user
          end
        end
      end

      let(:test_model) { double("User", is_a?: true, name: "User") }

      before do
        stub_const("User", test_model)

        allow(test_model).to receive(:find_by).and_return(nil)
        allow(test_model).to receive(:find_by).with(id: 1).and_return(double("User", present?: true))
      end

      it "exposes readers" do
        result = action.call!(foo: { user_id: 1 })
        expect(result).to be_ok
        expect(result.the_user.inspect).to eq(test_model.inspect)
        expect(result.user_id).to eq(1)
      end

      it "validates" do
        expect(action.call(foo: { user_id: nil })).not_to be_ok
        expect(action.call(foo: { user_id: 2 })).not_to be_ok
      end

      context "using expects shortcut to set exposure of same name" do
        subject(:result) { action.call!(foo: { user_id: 1 }) }

        let(:action) do
          build_axn do
            expects :foo
            expects :user_id, model: true, on: :foo
            exposes :user, :user_id

            def call
              expose :user_id, user_id
              expose :user, user
            end
          end
        end

        # TODO: circle back to this when we tackle supporting passing user in directly for model: true
        # it "exposes readers" do
        #   pending "TODO: add support for exposing the same field name as the expects shortcut readers"
        #   expect(result).to be_ok
        #   expect(result.the_user.inspect).to eq(test_model.inspect)
        #   expect(result.user_id).to eq(1)
        # end
      end
    end
  end

  describe "Axn::Internal::Logging.piping_error integration" do
    let(:action) do
      build_axn do
        expects :foo, validate: { with: ->(_v) { raise ArgumentError, "fail message" } }
      end
    end

    before do
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when custom validation raises" do
      result = action.call(foo: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect_piping_error_called(
        message_substring: "applying custom validation",
        error_class: ArgumentError,
        error_message: "fail message",
      )
    end
  end

  describe "Axn::Internal::Logging.piping_error integration for model validation" do
    let(:test_model) { double("User", is_a?: true, name: "User") }
    let(:action) do
      build_axn do
        expects :user_id, model: true
      end
    end

    before do
      stub_const("User", test_model)
      allow(test_model).to receive(:find_by).and_raise(ArgumentError, "fail model validation")
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when model validation raises" do
      result = action.call(user_id: 1)
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect_piping_error_called(
        message_substring: "applying model validation",
        error_class: ArgumentError,
        error_message: "fail model validation",
      )
    end
  end

  describe "inheritance and contracts" do
    let(:base) do
      build_axn do
        expects :foo, type: Numeric, numericality: { greater_than: 10 }
        exposes :bar, type: Numeric

        def call
          expose bar: base_thing
        end

        def base_thing = foo * 10
      end
    end

    let(:version_a) do
      Class.new(base) do
        expects :baz, default: 123
      end
    end

    let(:version_b) do
      Class.new(base) do
        expects :baz
        exposes :quz

        def call
          expose bar: baz
          expose quz: 999
        end
      end
    end

    it "does not modify other classes' configs when inheriting" do
      config_ids = [base, version_a, version_b].map(&:internal_field_configs).map(&:object_id)
      expect(config_ids.uniq.size).to eq(3)
      expect(base.call(foo: 11).bar).to eq(110)

      a = version_a.call(foo: 11)
      expect(a).to be_ok
      expect(a.bar).to eq(110)

      b = version_b.call(foo: 11, baz: 10)
      expect(b).to be_ok
      expect(b.bar).to eq(10)
      expect(b.quz).to eq(999)

      expect(version_b.call(baz: 10)).not_to be_ok
    end
  end

  describe "inheritance via explicit inclusion" do
    let(:custom_action_with_foo) do
      Module.new do
        def self.included(base)
          base.class_eval do
            include Axn
            expects :foo, type: Numeric, numericality: { greater_than: 10 }
            exposes :bar, type: Numeric
            def call
              expose bar: foo * 10
            end
          end
        end
      end
    end

    before do
      stub_const("CustomActionWithFoo", custom_action_with_foo)
    end

    let(:composed_class) do
      Class.new do
        include CustomActionWithFoo
        expects :baz, default: 123

        def call
          # Override the module's call method but still validate foo
          expose bar: baz
        end
      end
    end

    let(:inherited_class) do
      Class.new(composed_class)
    end

    before do
      stub_const("ComposedClass", composed_class)
      stub_const("InheritedClass", inherited_class)
    end

    shared_examples "an action" do |bar_value|
      context "when valid" do
        subject { action.call(foo: 11) }

        it { is_expected.to be_ok }
        it { expect(subject.bar).to eq bar_value }
      end

      context "when invalid" do
        subject { action.call(foo: 1) }

        it { is_expected.not_to be_ok }
        it { expect(subject.exception).to be_a(Axn::InboundValidationError) }
      end
    end

    context "when called directly" do
      let(:action) { build_axn { include CustomActionWithFoo } }
      it_behaves_like "an action", 110
    end

    context "when called on composed class" do
      let(:action) { ComposedClass }

      it_behaves_like "an action", 123
    end

    context "when called on inherited class" do
      let(:action) { InheritedClass }

      it_behaves_like "an action", 123
    end
  end

  describe "interface interdependencies" do
    describe "default accepts proc" do
      let(:action) do
        build_axn do
          expects :channel, default: -> { valid_channels.first }

          def call
            log "Got channel: #{channel}"
          end

          private

          def valid_channels = %w[web email sms].freeze
        end
      end

      subject { action.call }

      it { is_expected.to be_ok }
      it "sets the default channel value" do
        # Create an action instance to access its internal context for verification
        action_instance = action.new
        action_instance._run
        expect(action_instance.instance_variable_get("@__context").provided_data[:channel]).to eq("web")
      end
    end

    context "interdependencies to consider for future support" do
      describe "validations can reference instance methods" do
        let(:action) do
          build_axn do
            expects :channel, inclusion: { in: :valid_channels_for_number }
            expects :number

            def call
              log "Got channel: #{channel}"
            end

            private

            def base_channels = %w[web email sms]

            def valid_channels_for_number
              return ["channel_for_1"] if number == 1

              base_channels
            end
          end
        end

        it { expect(action.call(number: 1, channel: "channel_for_1")).to be_ok }
        it { expect(action.call(number: 2, channel: "channel_for_1")).not_to be_ok }

        it { expect(action.call(number: 2, channel: "sms")).to be_ok }
        it { expect(action.call(number: 1, channel: "sms")).not_to be_ok }
      end

      describe "validations can reference class methods methods" do
        let(:action) do
          build_axn do
            # NOTE: only works if method already defined!
            def self.valid_channels_for_number = ["overridden_valid_channels"]

            expects :channel, inclusion: { in: valid_channels_for_number }

            def call
              log "Got channel: #{channel}"
            end
          end
        end

        it { expect(action.call(channel: "overridden_valid_channels")).to be_ok }
        it { expect(action.call(channel: "any_other_value")).not_to be_ok }
      end
    end
  end
end
