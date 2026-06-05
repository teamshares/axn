# frozen_string_literal: true

RSpec.describe Axn do
  describe "return shape" do
    subject { action.call }

    context "when successful" do
      let(:action) { build_axn {} }

      it "is ok" do
        is_expected.to be_ok
      end
    end

    context "when fail! (user facing error)" do
      let(:action) do
        build_axn do
          def call
            fail!("User-facing error")
          end
        end
      end

      it "is not ok" do
        is_expected.not_to be_ok
        expect(subject.error).to eq("User-facing error")
        expect(subject.exception).to be_a(Axn::Failure)
        expect(subject.exception.message).to eq("User-facing error")
      end
    end

    context "when exception raised" do
      let(:action) do
        build_axn do
          def call
            raise "Some internal issue!"
          end
        end
      end

      it "is not ok" do
        expect { subject }.not_to raise_error
        is_expected.not_to be_ok
        expect(subject.error).to eq("Something went wrong")
        expect(subject.exception).to be_a(RuntimeError)
        expect(subject.exception.message).to eq("Some internal issue!")
      end
    end
  end

  describe "modifying exposed objects" do
    describe "modifying exposed object" do
      let(:action) do
        build_axn do
          exposes :preferences, type: Hash

          def call
            @prefs = { foo: "bar" }
            expose preferences: @prefs
            @prefs[:foo] = "baz"
          end
        end
      end

      it "returns the modified object" do
        result = action.call
        expect(result).to be_ok
        expect(result.preferences).to eq({ foo: "baz" })
      end
    end

    describe "modifying expected and re-exposed object" do
      let(:action) do
        build_axn do
          expects :preferences, type: Hash
          exposes :preferences, type: Hash

          def call
            preferences[:foo] = "before"
            expose(preferences:)
            preferences[:foo] = "final"
          end
        end
      end

      # TODO: do we WANT this? We could .dup, but then potentially much bigger memory usage.
      # Presumably we should just let consumer use .dup if they need it, but worth confirming...
      it "returns the modified object AND MODIFIES THE OBJECT THAT WAS " do
        preferences = { foo: "initial" }
        result = action.call(preferences:)
        expect(result).to be_ok
        expect(result.preferences).to eq({ foo: "final" })
        expect(preferences).to eq({ foo: "final" })
        expect(result.preferences.object_id).to eq(preferences.object_id)
      end
    end

    describe "re-exposing an expected kwarg without a manual expose call" do
      let(:action) do
        build_axn do
          expects :preferences, type: Hash
          exposes :preferences, type: Hash

          def call
            preferences[:foo] = "mutated"
            # no expose call — auto-copied from provided_data at outbound contract step
          end
        end
      end

      it "exposes the mutated object without requiring an explicit expose call" do
        preferences = { foo: "initial" }
        result = action.call(preferences:)
        expect(result).to be_ok
        expect(result.preferences).to eq({ foo: "mutated" })
        expect(result.preferences.object_id).to eq(preferences.object_id)
      end
    end
  end

  describe "exposures on non-success paths" do
    # exposes-declared fields that weren't explicitly exposed should still be
    # auto-copied from provided_data on fail! and exception paths — consistent
    # with success. nil is worse than a possibly-partial object; callers check
    # result.ok? before using the data, and withholding it helps no one.

    let(:item) { { value: "original" } }

    shared_examples "exposes expected kwargs" do |outcome_label|
      it "auto-copies the expected kwarg to the result (#{outcome_label})" do
        expect(result.item).to eq(item)
        expect(result.item.object_id).to eq(item.object_id)
      end

      it "preserves in-place mutations made before the failure (#{outcome_label})" do
        expect(result.item[:value]).to eq("mutated")
      end
    end

    context "when fail! is called" do
      let(:action) do
        build_axn do
          expects :item, type: Hash
          exposes :item, type: Hash

          def call
            item[:value] = "mutated"
            fail!("something went wrong")
          end
        end
      end

      let(:result) { action.call(item:) }

      include_examples "exposes expected kwargs", "fail!"

      it "is not ok" do
        expect(result).not_to be_ok
      end
    end

    context "when an unhandled exception is raised" do
      let(:action) do
        build_axn do
          expects :item, type: Hash
          exposes :item, type: Hash

          def call
            item[:value] = "mutated"
            raise "something exploded"
          end
        end
      end

      let(:result) { action.call(item:) }

      include_examples "exposes expected kwargs", "exception"

      it "is not ok" do
        expect(result).not_to be_ok
      end
    end

    context "when an explicitly exposed field was set before fail!" do
      let(:action) do
        build_axn do
          expects :item, type: Hash
          exposes :item, type: Hash
          exposes :extra, optional: true

          def call
            expose(extra: "set before failure")
            item[:value] = "mutated"
            fail!("something went wrong")
          end
        end
      end

      let(:result) { action.call(item:) }

      it "keeps the explicitly exposed value" do
        expect(result.extra).to eq("set before failure")
      end

      it "also auto-copies the expected kwarg" do
        expect(result.item[:value]).to eq("mutated")
      end
    end
  end
end
