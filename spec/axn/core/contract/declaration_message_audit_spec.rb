# frozen_string_literal: true

# The controls for `spec/support/declaration_message_audit.rb`, which holds every declaration refusal the suite
# asserts to three properties of its message. A lint that never fires looks exactly like one with nothing to
# find, so each property is shown to catch a message that breaks it, through the same matcher path the suite's
# own `raise_error` expectations take.
RSpec.describe "the declaration message audit" do
  describe ".defects" do
    def defects(message, label: "expects :v", frames: nil, depth: nil) = DeclarationMessageAudit.defects(message, label:, frames:, depth:)

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
      ["expects :v", "exposes :\"a.b\"", "expects payload.company_id", "shape member `sku` in expects :rows"].each do |named|
        expect(defects("`x:` isn't allowed on #{named}.", label: named)).to be_empty
      end
      expect(defects("an `expects` field name must be a String or Symbol", label: nil)).to be_empty
    end

    # Something shaped like a declaration is not enough: a sibling's, an outer field's or a stale label reads just
    # as well and points the author at the wrong line.
    it "flags a refusal that names a different, valid declaration" do
      expect(defects("`x:` isn't allowed on expects :w.")).to include("names a declaration other than the one it refuses (expects :v)")
      expect(defects("`x:` isn't allowed on expects :rows.", label: "shape member `sku` in expects :rows"))
        .to include("names a declaration other than the one it refuses (shape member `sku` in expects :rows)")
    end

    # A label is matched whole: one that is a prefix of the label the message renders names a different field.
    it "flags a refusal whose label only begins with this declaration's" do
      expect(defects("`x:` isn't allowed on expects :value.")).to include("names a declaration other than the one it refuses (expects :v)")
      expect(defects("`x:` isn't allowed on expects :v.w.")).to include("names a declaration other than the one it refuses (expects :v)")
      expect(defects("`x:` isn't allowed on expects :v.")).to be_empty
    end

    # The label current at the raise must belong to the declaration that raised: a nested `expects` refusing its
    # own name before it is known must not borrow the enclosing declaration's label and pass by naming it.
    it "flags a refusal raised by a declaration whose own label was not current" do
      expect(defects("`x:` isn't allowed on expects :v.", frames: 2, depth: 1))
        .to include(/was raised by a declaration whose own label was not current/)
      expect(defects("`x:` isn't allowed on expects :v.", frames: 1, depth: 1)).to be_empty
    end

    it "matches a label carrying regexp characters literally, and whole" do
      label = 'exposes :"a.b"'
      expect(defects('`x:` isn\'t allowed on exposes :"a.b".', label:)).to be_empty
      expect(defects('`x:` isn\'t allowed on exposes :"aXb".', label:)).to include(%(names a declaration other than the one it refuses (#{label})))
    end

    it "matches a label with a quoted path segment whole" do
      label = 'expects "x y".a'
      expect(defects('inclusion: on expects "x y".a can never match.', label:)).to be_empty
      expect(defects('inclusion: on expects "x y".ab can never match.', label:)).to include(%(names a declaration other than the one it refuses (#{label})))
    end

    it "refuses to judge against a blank label rather than passing every message" do
      expect { defects("anything", label: " ") }.to raise_error(ArgumentError, /blank declaration label/)
    end

    it "accepts a refusal about another config that names this declaration as well" do
      expect(defects("expects :payload is declared nil-tolerant. Found while declaring expects :v.")).to be_empty
    end

    # An exempt refusal is spared naming the declaration, never the other two properties.
    it "still holds a refusal exempt from naming its declaration to rendering no address and no Array" do
      loop_message = "`on:` loops back on itself — expects a.x (read as :b) -> expects b.y (read as :a) -> expects a.x: each is ..."
      expect(defects(loop_message, label: "expects b.y")).to be_empty
      expect(defects("#{loop_message} #<Class:0x000000012b647db0>", label: "expects b.y")).to include("renders a memory address")
      expect(defects(%(#{loop_message} ["y"]), label: "expects b.y")).to include("renders a declared field as an Array inspect")
    end

    it "reads the field names out of each label shape" do
      expect(DeclarationMessageAudit.field_names("expects :a, :b")).to eq(%w[a b])
      expect(DeclarationMessageAudit.field_names("expects payload.company_id")).to eq(%w[company_id])
      expect(DeclarationMessageAudit.field_names("shape member `sku` in expects :rows")).to eq(%w[sku rows])
      expect(DeclarationMessageAudit.field_names(nil)).to eq([])
    end
  end

  describe ".outside_defects" do
    def outside_defects(message, carried: []) = DeclarationMessageAudit.outside_defects(message, carried:)

    it "flags a class or module axn named by its address" do
      expect(outside_defects("`tool` was already declared on #<Class:0x000000012b647db0>; declare all adapters"))
        .to include("renders a class or module by its memory address")
      expect(outside_defects("got :other after use under #<Module:0x000000012b647db0>"))
        .to include("renders a class or module by its memory address")
      expect(outside_defects("got #<#<Class:0x000000012b647db0> (inspect unavailable)>"))
        .to include("renders a class or module by its memory address")
    end

    it "passes the placeholder" do
      expect(outside_defects("`tool` was already declared on (anonymous class); declare all adapters")).to be_empty
    end

    # The caller's own rendering of their own object, and Ruby's phrasing inside a caller's exception message.
    it "passes an address that is a caller's object rendering or Ruby's own phrasing" do
      expect(outside_defects("step if: must be a Symbol or callable (got #<Object:0x000000012b647db0>)")).to be_empty
      expect(outside_defects("Unclear how to extract leaf from #<#<Class:0x000000012b647db0>:0x000000012b647dc8 @id=7>")).to be_empty
      expect(outside_defects("failed validation: undefined method `helper' for an instance of #<Class:0x000000012b647db0>")).to be_empty
      expect(outside_defects("undefined method `log' for class #<Class:0x000000012b647db0>")).to be_empty
    end

    it "passes an address the error's cause carries, and only that one" do
      carried = ["#<Class:0x000000012b647db0>"]
      expect(outside_defects("re-raised ...; its message was: #<Class:0x000000012b647db0>", carried:)).to be_empty
      expect(outside_defects("not as the original #<Class:0x000000012b647dc8>; its message was: #<Class:0x000000012b647db0>", carried:))
        .to include("renders a class or module by its memory address")
    end
  end

  # End to end, outside a declaration: an error axn raises from lib/ with a class named by its address must fail the
  # `raise_error` expectation that receives it, while a caller's own error re-raised through lib/ is left alone.
  describe "the raise_error hook, outside a declaration" do
    it "fails an expectation whose error names a class by its address" do
      action = Class.new { include Axn }
      action.tool :mcp
      allow(Axn::Internal::Rendering).to receive(:installed_name).and_return("#<Class:0x000000012b647db0>")

      expect { expect { action.tool :mcp }.to raise_error(ArgumentError) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /error axn raised renders a class or module by its memory address/)
    end

    it "leaves a caller's error that lib/ re-raises alone" do
      action = Class.new do
        include Axn
        def call = raise(ArgumentError, "the caller's #<Class:0x000000012b647db0>")
      end

      expect { expect { action.call! }.to raise_error(ArgumentError) }.not_to raise_error
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

    it "fails an expectation whose refusal names a sibling declaration instead" do
      refused_with("expects :w")
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /names a declaration other than the one it refuses \(expects :v\)/)
    end

    # An audit that cannot read the message fails the example rather than passing it unjudged — a spec asserting
    # only the class would otherwise see nothing.
    it "fails the example when the refusal's message cannot be rendered" do
      unreadable = Class.new(ArgumentError) { def message = raise("message cannot be rendered") }.new
      DeclarationMessageAudit.tag(unreadable, "expects :v")

      expect { expect { raise unreadable }.to raise_error(ArgumentError) }.to raise_error(RuntimeError, "message cannot be rendered")
    end

    # A spec asserting a wrapper still has the refusal it wraps judged.
    it "judges a refusal reached through the asserted error's cause" do
      allow(action).to receive(:_declared_fields_label).and_return("expects :w")
      wrapped = lambda do
        action.expects :v, type: Integer, allow_empty: true
      rescue ArgumentError
        raise "wrapped"
      end
      expect { expect { wrapped.call }.to raise_error(RuntimeError, "wrapped") }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /names a declaration other than the one it refuses/)
    end

    # A refusal a spec rescues itself, rather than through `raise_error`, is collected and judged when the example
    # ends (Ruby 3.3+, which reports `rescue`). Judged here directly so the control does not fail its own example.
    it "collects a refusal a spec rescues itself" do
      skip "needs TracePoint(:rescue), Ruby 3.3+" if DeclarationMessageAudit::RESCUE_TRACE.nil?

      allow(action).to receive(:_declared_fields_label).and_return("expects :w")
      refusal = begin
        action.expects :v, type: Integer, allow_empty: true
      rescue ArgumentError => e
        e
      end

      expect(DeclarationMessageAudit::OBSERVED).to have_key(refusal)
      DeclarationMessageAudit::OBSERVED.delete(refusal)
      expect { DeclarationMessageAudit.judge!(refusal) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /names a declaration other than the one it refuses/)
    end

    it "leaves a refusal the library rescues itself unjudged" do
      skip "needs TracePoint(:rescue), Ruby 3.3+" if DeclarationMessageAudit::RESCUE_TRACE.nil?

      # Blankness is probed on these bytes with a match that raises `ArgumentError` inside lib/, which rescues it.
      expect do
        build_axn do
          expects :par, type: Hash
          expects :a, on: (+"\xff").force_encoding("UTF-8"), optional: true
        end
      end.to raise_error(EncodingError)
      expect(DeclarationMessageAudit::INTERNAL).not_to be_empty
      expect(DeclarationMessageAudit::OBSERVED).to be_empty
    end

    it "leaves an error raised outside a declaration alone" do
      expect { expect { raise ArgumentError, 'on ["v"] #<Class:0x000000012b647db0>' }.to raise_error(ArgumentError) }
        .not_to raise_error
    end
  end
end
