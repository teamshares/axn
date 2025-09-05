# frozen_string_literal: true

# TODO: was used for manual testing -- clean up or remove when done

RSpec.describe "One-off confirmation" do
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
end
