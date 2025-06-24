# frozen_string_literal: true

RSpec.describe Action do
  describe "expects_fields" do
    shared_examples "raises when improperly configured" do |on:|
      it "raises" do
        expect { action }.to raise_error(
          ArgumentError,
          "expects_fields called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)",
        )
      end
    end

    context "when missing expects declaration" do
      let(:action) { build_action { expects_fields :bar, on: :baz } }
      it_behaves_like "raises when improperly configured", on: :baz
    end

    context "when missing nested expects_fields declaration" do
      let(:action) do
        build_action do
          expects :baz
          expects_fields :bar, on: :baz
          expects_fields :quux, on: :qux
        end
      end
      it_behaves_like "raises when improperly configured", on: :qux
    end

    let(:action) do
      build_action do
        expects :foo
        expects_fields :bar, :baz, on: :foo
        expects_fields :qux, on: :bar
      end
    end

    it "validates" do
      expect(action.call(foo: { bar: { qux: 3 }, baz: 2 })).to be_ok
      expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
      expect(action.call(foo: 1)).not_to be_ok
    end
  end
end
