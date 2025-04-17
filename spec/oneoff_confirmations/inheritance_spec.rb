# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

# NOTE: requires upstream interactor branch for support -- see TODO in Gemfile

module CustomActionWithFoo
  def self.included(base)
    base.class_eval do
      include Action
      expects :foo, type: Numeric, numericality: { greater_than: 10 }
      exposes :bar, type: Numeric
      def call
        expose bar: foo * 10
      end
    end
  end
end

class ComposedClass
  include CustomActionWithFoo
  expects :baz, default: 123

  def call
    expose bar: baz
  end
end

class InheritedClass < ComposedClass
end

RSpec.describe "One-off confirmation: inheritance via explicit" do
  shared_examples "an action" do |bar_value|
    context "when valid" do
      subject { action.call(foo: 11) }

      it { is_expected.to be_ok }
      it { expect(subject.bar).to eq bar_value }
    end

    context "when invalid" do
      subject { action.call(foo: 1) }

      it { is_expected.not_to be_ok }
      it { expect(subject.exception).to be_a(Action::InboundValidationError) }
    end
  end

  context "when called directly" do
    let(:action) { Class.new.send(:include, CustomActionWithFoo) }
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
