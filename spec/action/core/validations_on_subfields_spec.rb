# frozen_string_literal: true

RSpec.describe Action do
  describe "_expects_subfields" do
    shared_examples "raises when improperly configured" do |on:|
      it "raises" do
        expect { action }.to raise_error(
          ArgumentError,
          "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)",
        )
      end
    end

    context "when missing expects declaration" do
      let(:action) { build_action { expects :bar, on: :baz } }
      it_behaves_like "raises when improperly configured", on: :baz
    end

    context "when missing nested expects declaration" do
      let(:action) do
        build_action do
          expects :baz
          expects :bar, on: :baz
          expects :quux, on: :qux
        end
      end
      it_behaves_like "raises when improperly configured", on: :qux
    end

    let(:readers) { true }
    let(:action) do
      build_action do
        expects :foo
        expects :bar, :baz, on: :foo
        exposes :output

        def call
          expose output: qux
        end
      end.tap do |action|
        action.expects :qux, on: :bar, readers:
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
          expects "bar.baz", on: :foo
        end
      end

      it "validates" do
        expect(action.call(foo: { bar: { baz: 3 } })).to be_ok
        expect(action.call(foo: { bar: 1, baz: 2 })).not_to be_ok
        expect(action.call(foo: 1)).not_to be_ok
      end

      context "with duplicate sub-keys" do
        let(:action) do
          build_action do
            expects :foo
            expects :bar, on: :foo
          end.tap do |a|
            a.expects :foo, on: :bar, readers:
          end
        end

        context "when readers are enabled" do
          let(:readers) { true }

          it "raises if readers are enabled" do
            expect { action }.to raise_error(ArgumentError, "expects does not support duplicate sub-keys (i.e. `foo` is already defined)")
          end
        end

        context "when readers are disabled" do
          let(:readers) { false }

          it "does not raise" do
            expect { action }.not_to raise_error
            expect(action.call(foo: { bar: { foo: 3 } })).to be_ok
            expect(action.call(foo: { bar: { baz: 3 } })).not_to be_ok
          end
        end
      end
    end

    context "with objects rather than hashes" do
      let(:action) do
        build_action do
          expects :foo
          expects :bar, on: :foo
        end
      end
      let(:foo) { double(bar: 3) }

      it "validates" do
        expect(action.call(foo:)).to be_ok
      end
    end
  end
end
