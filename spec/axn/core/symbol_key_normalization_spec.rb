# frozen_string_literal: true

RSpec.describe Axn do
  describe "symbol key normalization (PRO-2790)" do
    # The four-row table from the ticket: declared-key type × call-arg-key type.
    # Coerce: all four resolve to the same successful read.
    describe "read path — call-arg key vs declared-field key" do
      context "symbol field declaration" do
        it "works with a symbol call key" do
          result = build_reader_action.call(note: "hello")
          expect(result).to be_ok
          expect(result.saved).to eq("HELLO")
        end

        it "works with a string call key (the **params trap)" do
          result = build_reader_action.call("note" => "hello")
          expect(result).to be_ok
          expect(result.saved).to eq("HELLO")
        end
      end

      context "string field declaration" do
        it "works with a symbol call key" do
          result = build_reader_action(declare: "note").call(note: "hello")
          expect(result).to be_ok
          expect(result.saved).to eq("HELLO")
        end

        it "works with a string call key" do
          result = build_reader_action(declare: "note").call("note" => "hello")
          expect(result).to be_ok
          expect(result.saved).to eq("HELLO")
        end
      end
    end

    describe "write path — expose key vs declared-exposure key" do
      it "reads back a string-keyed positional expose against a string declaration" do
        action = build_axn do
          exposes "saved"
          define_method(:call) { expose("saved", "hi") }
        end
        result = action.call
        expect(result).to be_ok
        expect(result.saved).to eq("hi")
      end

      it "reads back a string-keyed hash expose" do
        action = build_axn do
          exposes :saved
          define_method(:call) { expose("saved" => "hi") }
        end
        result = action.call
        expect(result).to be_ok
        expect(result.saved).to eq("hi")
      end

      it "reads back a string expose_return_as" do
        action = Axn::Factory.build(expose_return_as: "saved") { "hi" }
        result = action.call
        expect(result).to be_ok
        expect(result.saved).to eq("hi")
      end
    end

    describe "declaration normalization" do
      it "symbolizes the wire key so config.field is always a symbol" do
        action = build_axn { expects "note" }
        expect(action.internal_field_configs.map(&:field)).to eq([:note])
      end

      it "defines a symbol-named reader for a string declaration" do
        action = build_reader_action(declare: "note")
        result = action.call(note: "hi")
        expect(result.saved).to eq("HI")
      end

      it "treats :note and \"note\" as the same field (duplicate)" do
        expect { build_axn { expects :note, "note" } }
          .to raise_error(Axn::DuplicateFieldError, /note/)
      end

      it "symbolizes exposes wire keys too" do
        action = build_axn { exposes "saved" }
        expect(action.external_field_configs.map(&:field)).to eq([:saved])
      end
    end

    def build_reader_action(declare: :note)
      build_axn do
        expects declare
        exposes :saved
        define_method(:call) { expose(saved: note.upcase) }
      end
    end
  end
end
