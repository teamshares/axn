# frozen_string_literal: true

# A colliding or unrenderable property name only harms a JSON projection, and for a tool axn the projection is
# what an adapter hands a model — so validation is driven at app setup rather than left to a user's tool call.
# This is the non-Rails path: there is no boot to hook, so an app calls the entry point itself. The Rails hooks
# that call the same entry point are covered in `spec_rails`.
RSpec.describe "Axn.validate_tool_contracts!" do
  before { Axn::Tools::Registry.reset_adapters! }
  after { Axn::Tools::Registry.reset_adapters! }

  # Named, because the registry deliberately drops anonymous classes from enumeration — an anonymous class has no
  # stable tool_name and could never be a usable tool.
  #
  # Two shape members whose names canonicalize to one property. Chosen because no eager rule sees it — only the
  # emitted-property walk does, so the class declares cleanly and stays invalid until something projects it.
  def colliding_tool(name = "ToolContractsSpec::Colliding", adapters: [:mcp])
    latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
    stub_const(name, Class.new do
      include Axn
      tool(*adapters)
      expects(:payload, type: Hash) do
        field :café, type: String
        field latin1, type: Integer
      end
      def call; end
    end)
  end

  def valid_tool(name = "ToolContractsSpec::Valid", adapters: [:mcp])
    stub_const(name, Class.new do
      include Axn
      tool(*adapters)
      expects :a, optional: true
      def call; end
    end)
  end

  it "raises for a tool whose contract collapses onto one property" do
    Axn.register_tool_adapter(:mcp)
    colliding_tool

    expect { Axn.validate_tool_contracts! }.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
  end

  # This runs over every tool at once, so the first thing an author needs is WHICH tool — the underlying error
  # describes the property and the colliding declarations but not the class.
  it "names the offending class, keeping the original as the cause" do
    Axn.register_tool_adapter(:mcp)
    colliding_tool

    expect { Axn.validate_tool_contracts! }.to raise_error(Axn::DuplicateFieldError) { |error|
      expect(error.message).to start_with("ToolContractsSpec::Colliding has an invalid tool contract")
      expect(error.cause).to be_a(Axn::DuplicateFieldError)
    }
  end

  # An unrenderable name raises ArgumentError rather than a ContractViolation, so both families have to be
  # wrapped or one of them would reach boot unnamed.
  it "names the offending class for an unrenderable name too" do
    Axn.register_tool_adapter(:mcp)
    bad = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym
    stub_const("ToolContractsSpec::Unrenderable", Class.new do
      include Axn
      tool :mcp
      expects(:payload, type: Hash) { field bad, type: String }
      def call; end
    end)

    expect { Axn.validate_tool_contracts! }.to raise_error(ArgumentError) { |error|
      expect(error.message).to start_with("ToolContractsSpec::Unrenderable has an invalid tool contract")
      expect(error.message).to include("bytes that have no UTF-8 rendering")
    }
  end

  it "passes over valid tools" do
    Axn.register_tool_adapter(:mcp)
    valid_tool

    expect { Axn.validate_tool_contracts! }.not_to raise_error
  end

  # The point of running at setup: without it the same contract reaches an adapter, and the error surfaces from
  # whatever first projects — which for a tool is a model-facing call.
  it "leaves the same error to first projection when never called" do
    Axn.register_tool_adapter(:mcp)
    klass = colliding_tool

    expect { klass.input_schema }.to raise_error(Axn::DuplicateFieldError)
  end

  # Validation is adapter-agnostic, so a tool registered for two adapters is projected once rather than once per
  # adapter. Counted at the walk, since the memo is what makes the second projection free.
  it "validates each tool once regardless of how many adapters claim it" do
    Axn.register_tool_adapter(:mcp)
    Axn.register_tool_adapter(:ruby_llm)
    valid_tool(adapters: %i[mcp ruby_llm])
    walks = 0
    allow(Axn::Reflection::PropertyNames).to receive(:reject_colliding_emitted_properties!).and_wrap_original do |original, *args, &block|
      walks += 1
      original.call(*args, &block)
    end

    Axn.validate_tool_contracts!

    # One inbound projection and one outbound, not two of each.
    expect(walks).to eq(2)
  end

  it "does not project non-tool axns" do
    Axn.register_tool_adapter(:mcp)
    latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
    stub_const("ToolContractsSpec::NotATool", Class.new do
      include Axn
      expects(:payload, type: Hash) do
        field :café, type: String
        field latin1, type: Integer
      end
      def call; end
    end)

    expect { Axn.validate_tool_contracts! }.not_to raise_error
  end

  # A second setup pass (a dev reload calls the entry point again) must stay silent for a valid contract and stay
  # loud for an invalid one — a memo that swallowed the second would hide it from every reload after the first.
  it "keeps raising across repeated setup passes" do
    Axn.register_tool_adapter(:mcp)
    colliding_tool

    expect { Axn.validate_tool_contracts! }.to raise_error(Axn::DuplicateFieldError)
    expect { Axn.validate_tool_contracts! }.to raise_error(Axn::DuplicateFieldError)
  end

  describe "Registry.tool_classes" do
    # The registry is process-global, so this asserts membership rather than an exact set: another spec's named
    # tool class may legitimately still be defined.
    it "enumerates tools independent of tools_for" do
      Axn.register_tool_adapter(:mcp)
      tool = valid_tool
      plain = stub_const("ToolContractsSpec::Plain", Class.new { include Axn })

      classes = Axn::Tools::Registry.tool_classes

      expect(classes).to include(tool)
      expect(classes).not_to include(plain)
    end
  end
end
