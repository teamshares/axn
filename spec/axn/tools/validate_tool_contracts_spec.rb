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

  # THE case that matters most, and the one the guarantee used to miss: a tool subclassing its adapter's base
  # class, which is the ordinary shape of one (`Axn::MCP::Tool < ::MCP::Tool`). That base already defines
  # `input_schema`/`output_schema`, so axn deliberately does not install its own (see Core::SchemaReflection) —
  # and setup that reached the projection through the class method called the adapter's transport reader,
  # validated nothing, and let the collision through to the model. Setup builds axn's own projections instead.
  describe "a tool that inherits its adapter's schema readers" do
    def adapter_base
      stub_const("ToolContractsSpec::AdapterBase", Class.new do
        def self.input_schema = { "transport" => "in" }
        def self.output_schema = { "transport" => "out" }
      end)
    end

    def shadowing_tool(inbound:)
      base = adapter_base
      latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
      stub_const("ToolContractsSpec::Shadowing", Class.new(base) do
        include Axn
        tool
        if inbound
          expects(:payload, type: Hash) do
            field :café, type: String
            field latin1, type: Integer
          end
        else
          exposes(:payload, type: Hash) do
            field :café, type: String
            field latin1, type: Integer
          end
        end
        def call = expose(payload: {})
      end)
    end

    it "keeps the adapter's readers rather than axn's" do
      Axn.register_tool_adapter(:mcp)
      klass = shadowing_tool(inbound: true)

      expect(klass.input_schema).to eq({ "transport" => "in" })
      expect(klass.output_schema).to eq({ "transport" => "out" })
    end

    it "still validates its inbound contract at setup" do
      Axn.register_tool_adapter(:mcp)
      shadowing_tool(inbound: true)

      expect { Axn.validate_tool_contracts! }
        .to raise_error(Axn::DuplicateFieldError, /Shadowing has an invalid tool contract.*JSON property "café"/m)
    end

    # The outbound half was already immune — `validate_outbound!` builds from the configs and never called
    # `output_schema` — asserted rather than assumed, since the same shadowing applies to that name.
    it "still validates its outbound contract at setup" do
      Axn.register_tool_adapter(:mcp)
      shadowing_tool(inbound: false)

      expect { Axn.validate_tool_contracts! }
        .to raise_error(Axn::DuplicateFieldError, /Shadowing has an invalid tool contract.*JSON property "café"/m)
    end
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
    tool = valid_tool(adapters: %i[mcp ruby_llm])
    # Counted on the TARGET class rather than globally: the registry is process-global, so another spec file's
    # named tool class may legitimately still be enumerable and would inflate a global count.
    # Counted at the BUILD rather than at `input_schema`: setup validates axn's own projection directly, since
    # `input_schema` may belong to an adapter base class (see the shadowing example below).
    projections = 0
    allow(Axn::Reflection::Schema).to receive(:build_input_for).and_wrap_original do |original, klass|
      projections += 1 if klass == tool
      original.call(klass)
    end

    Axn.validate_tool_contracts!

    expect(projections).to eq(1)
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

  # The width of the guarantee, pinned: membership is the union of a directory grant and a DECLARATION grant, so
  # a `tool`-DSL axn is enumerated with no tool root configured at all. What bounds coverage is whether the class
  # is LOADED and whether any adapter is registered — not whether it lives in a directory.
  describe "what enumeration covers" do
    it "enumerates a declaration-granted tool with no tool roots configured" do
      Axn.register_tool_adapter(:mcp)
      tool = valid_tool

      expect(Axn::Tools::Registry.send(:_all_adapter_dirs)).to be_empty
      expect(Axn::Tools::Registry.tool_classes).to include(tool)
    end

    # The local is NOT named `tool`: bare `tool` inside the class body would then parse as that local variable
    # (nil at that point) instead of the DSL method, and the fixture would declare no tool at all.
    it "enumerates a tool declared for every adapter (bare `tool`)" do
      Axn.register_tool_adapter(:mcp)
      bare = stub_const("ToolContractsSpec::BareTool", Class.new do
        include Axn
        tool
        expects :a, optional: true
        def call; end
      end)

      expect(bare._tool_declaration).to eq(:all)
      expect(Axn::Tools::Registry.tool_classes).to include(bare)
    end

    # With no adapter registered there is no membership to test, so setup validation is a no-op. An app that
    # expects it must register the adapter its tools are for.
    it "validates nothing when no adapter is registered" do
      colliding_tool

      expect(Axn::Tools::Registry.tool_classes).to be_empty
      expect { Axn.validate_tool_contracts! }.not_to raise_error
    end
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
