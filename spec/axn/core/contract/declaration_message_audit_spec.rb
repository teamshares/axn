# frozen_string_literal: true

# The controls for `spec/support/declaration_message_audit.rb`, which holds every declaration refusal the suite
# asserts to three properties of its message. A lint that never fires looks exactly like one with nothing to
# find, so each property is shown to catch a message that breaks it, through the same matcher path the suite's
# own `raise_error` expectations take.
RSpec.describe "the declaration message audit" do
  describe ".defects" do
    def defects(message, label: "expects :v") = DeclarationMessageAudit.defects(message, label:)

    it "passes a message that names the declaration, renders no Array and no address" do
      expect(defects("`allow_empty:` isn't allowed on expects :v for Integer — drop it.")).to be_empty
    end

    it "flags a declared field rendered as an Array inspect" do
      expect(defects('`allow_empty:` isn\'t allowed on expects :v for Integer, or on ["v"].'))
        .to include("renders a declared field as an Array inspect")
    end

    it "does not take an Array that names no declared field for one" do
      expect(defects('format: on expects :v cannot constrain a container (`format:` matches `["a"].to_s`).')).to be_empty
    end

    it "flags a memory address" do
      expect(defects("user_facing: must be true on expects :v (got a value of class #<Class:0x000000012b647db0>)"))
        .to include("renders a memory address")
    end

    it "flags a refusal that does not name the declaration" do
      expect(defects("allow_empty: must be true, false, or nil on :v (got a value of class Object)."))
        .to include("does not name the declaration (direction and field) it refuses")
    end

    it "accepts every label shape a declaration has" do
      ["expects :v", "exposes :\"a.b\"", "expects payload.company_id", "shape member `sku` in expects :rows",
       "an `expects` field name"].each do |named|
        expect(defects("`x:` isn't allowed on #{named}.")).to be_empty
      end
    end

    it "reads the field names out of each label shape" do
      expect(DeclarationMessageAudit.field_names("expects :a, :b")).to eq(%w[a b])
      expect(DeclarationMessageAudit.field_names("expects payload.company_id")).to eq(%w[company_id])
      expect(DeclarationMessageAudit.field_names("shape member `sku` in expects :rows")).to eq(%w[sku rows])
      expect(DeclarationMessageAudit.field_names(nil)).to eq([])
    end
  end

  # End to end: a real refusal raised from lib/ inside `expects`, with the label it renders replaced, must fail
  # the `raise_error` expectation that receives it.
  describe "the raise_error hook" do
    let(:action) { Class.new { include Axn } }

    def refused_with(label)
      allow(action).to receive(:_declared_fields_label).and_return(label)
      expect { expect { action.expects :v, type: Integer, allow_empty: true }.to raise_error(ArgumentError) }
    end

    it "fails an expectation whose refusal renders the field as an Array inspect" do
      refused_with('expects :v, ["v"]')
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /renders a declared field as an Array inspect/)
    end

    it "fails an expectation whose refusal renders a memory address" do
      refused_with("expects :v #<Class:0x000000012b647db0>")
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /renders a memory address/)
    end

    it "fails an expectation whose refusal does not name the declaration" do
      refused_with(":v").to raise_error(RSpec::Expectations::ExpectationNotMetError, /does not name the declaration/)
    end

    it "leaves an error raised outside a declaration alone" do
      expect { expect { raise ArgumentError, 'on ["v"] #<Class:0x000000012b647db0>' }.to raise_error(ArgumentError) }
        .not_to raise_error
    end
  end
end
