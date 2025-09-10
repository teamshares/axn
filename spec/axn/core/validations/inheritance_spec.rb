# frozen_string_literal: true

RSpec.describe Axn do
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
end
