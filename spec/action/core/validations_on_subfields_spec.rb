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

    let(:readers) { true }
    let(:action) do
      build_action do
        expects :foo
        expects_fields :bar, :baz, on: :foo
        exposes :output

        def call
          expose output: qux
        end
      end.tap do |action|
        action.expects_fields :qux, on: :bar, readers: readers
      end
    end

    it "validates" do
      expect(action.call(foo: { bar: { qux: 3 }, baz: 2 })).to be_ok
      expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
      expect(action.call(foo: 1)).not_to be_ok
    end

    context "readers" do
      subject(:result) { action.call(foo: { bar: { qux: 3 }, baz: 2 }) }

      it "exposes by default" do
        expect(result).to be_ok
        expect(result.output).to eq(3)
      end

      context "can be disabled" do
        let(:readers) { false }

        it do
          expect(result).not_to be_ok
          expect(result.exception).to be_a(NameError)
        end
      end
    end

    context "digging to nested fields" do
      let(:action) do
        build_action do
          expects :foo
          expects_fields "bar.baz", on: :foo
        end
      end

      it "validates" do
        expect(action.call(foo: { bar: { baz: 3 } })).to be_ok
        expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end
    end

    context "with objects rather than hashes" do
      let(:action) do
        build_action do
          expects :foo
          expects_fields :bar, on: :foo
        end
      end
      let(:foo) { double(bar: 3) }

      it "validates" do
        expect(action.call(foo:)).to be_ok
      end
    end
  end
end
