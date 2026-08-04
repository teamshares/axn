# frozen_string_literal: true

# A colliding or unrenderable property name only harms a JSON projection, and for a tool axn the projection is
# what an adapter hands a model — so validation is driven at app setup rather than left to a user's tool call.
# This is the non-Rails path: there is no boot to hook, so an app calls the entry point itself. The Rails hooks
# that call the same entry point are covered in `spec_rails`.
RSpec.describe "Axn::Tools.validate_contracts!" do
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
    Axn::Tools.register_adapter(:mcp)
    colliding_tool

    expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::ContractViolation::DuplicateFieldError, /both render as the JSON property "café"/)
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
      Axn::Tools.register_adapter(:mcp)
      klass = shadowing_tool(inbound: true)

      expect(klass.input_schema).to eq({ "transport" => "in" })
      expect(klass.output_schema).to eq({ "transport" => "out" })
    end

    it "still validates its inbound contract at setup" do
      Axn::Tools.register_adapter(:mcp)
      shadowing_tool(inbound: true)

      expect { Axn::Tools.validate_contracts! }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /Shadowing has an invalid tool contract.*JSON property "café"/m)
    end

    # The outbound half was already immune — `validate_outbound!` builds from the configs and never called
    # `output_schema` — asserted rather than assumed, since the same shadowing applies to that name.
    it "still validates its outbound contract at setup" do
      Axn::Tools.register_adapter(:mcp)
      shadowing_tool(inbound: false)

      expect { Axn::Tools.validate_contracts! }
        .to raise_error(Axn::ContractViolation::DuplicateFieldError, /Shadowing has an invalid tool contract.*JSON property "café"/m)
    end
  end

  # This runs over every tool at once, so the first thing an author needs is WHICH tool — the underlying error
  # describes the property and the colliding declarations but not the class.
  it "names the offending class, keeping the original as the cause" do
    Axn::Tools.register_adapter(:mcp)
    colliding_tool

    expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::ContractViolation::DuplicateFieldError) { |error|
      expect(error.message).to start_with("ToolContractsSpec::Colliding has an invalid tool contract")
      expect(error.cause).to be_a(Axn::ContractViolation::DuplicateFieldError)
    }
  end

  # Naming the tool must not cost the error. `raise e.class, message` CONSTRUCTS a new instance, which fails
  # outright for any exception whose initializer takes more than a message — so the wrapper meant to help
  # destroyed both the contract error and the class it promised to preserve. Raising the OBJECT clones it, runs
  # no initializer, and keeps class, state and cause.
  it "passes a structured exception through with its class, message and cause intact" do
    structured = Class.new(ArgumentError) do
      def initialize(path:)
        @path = path
        super(nil)
      end

      # Builds its own message from state, so the tool-name prefix cannot apply — its own message stands, which
      # is the documented boundary: a degraded message rather than a lost error.
      def message = "structured at #{@path}"
    end
    stub_const("ToolContractsSpec::Structured", structured)
    Axn::Tools.register_adapter(:mcp)
    klass = valid_tool
    allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).and_call_original
    allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).with(klass).and_raise(structured.new(path: "p"))

    expect { Axn::Tools.validate_contracts! }.to raise_error(structured) { |error|
      expect(error.message).to eq("structured at p")
      expect(error.cause).to be_a(structured)
    }
  end

  # Renaming the error runs the exception's own code, and this is the path that REPORTS a failure — so nothing
  # the exception defines may replace the failure being reported, least of all outside StandardError, which
  # escapes the rescue meant to settle it, at boot, naming nothing. Two rules, and the examples below are one per
  # branch of them: a dispatch axn makes is GUARDED, so at worst the message degrades; a dispatch `raise` makes
  # cannot be guarded, so an exception whose class owns `#exception` (or a duplication hook, or that is frozen) is
  # not renamed at all and is reported as axn's own error instead.
  describe "an exception whose own methods refuse to cooperate" do
    def raising_from(klass, error)
      Axn::Tools.register_adapter(:mcp)
      tool = valid_tool
      allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).and_call_original
      allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).with(tool).and_raise(error)
      stub_const("ToolContractsSpec::Hostile", klass)
    end

    # The surfaced error IS the contract failure, so nothing has to be recovered from `cause` — which is what the
    # old code got backwards: the interpolation's escape surfaced as a NotImplementedError that merely CARRIED the
    # contract failure as its cause.
    it "reports a #message that raises by its stored message, keeping its class" do
      hostile = Class.new(ArgumentError) do
        def message = raise(NotImplementedError, "hostile message")
      end
      raising_from(hostile, hostile.new("the real defect"))

      expect { Axn::Tools.validate_contracts! }.to raise_error(hostile) { |error|
        expect(Exception.instance_method(:to_s).bind_call(error))
          .to eq("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        # `cause` on a DEGRADED path: reading the hostile `#message` rescues inside the boot rescue, and Ruby
        # does not restore `$!` afterwards, so the implicit cause was nil here until it was passed explicitly.
        expect(error.cause).to be_a(hostile)
      }
    end

    it "reports one whose #message and #to_s both raise by its class alone" do
      hostile = Class.new(ArgumentError) do
        def message = raise(NotImplementedError, "hostile message")
        def to_s = raise(NotImplementedError, "hostile to_s")
      end
      raising_from(hostile, hostile.new)

      expect { Axn::Tools.validate_contracts! }.to raise_error(hostile) { |error|
        expect(Exception.instance_method(:to_s).bind_call(error))
          .to eq("ToolContractsSpec::Valid has an invalid tool contract — ToolContractsSpec::Hostile")
      }
    end

    # A `#message` that returns a hostile OBJECT rather than raising: interpolating it into the renamed message
    # would dispatch that object's `to_s` outside the guard, which is the same escape one indirection over. The
    # result is type-tested instead, so a non-String falls back to the stored message.
    it "ignores a #message that answers with an object whose to_s raises" do
      rude = Class.new do
        def to_s = raise(NotImplementedError, "hostile to_s")
      end
      hostile = Class.new(ArgumentError) do
        define_method(:message) { rude.new }
      end
      raising_from(hostile, hostile.new("the stored message"))

      expect { Axn::Tools.validate_contracts! }.to raise_error(hostile) { |error|
        expect(Exception.instance_method(:to_s).bind_call(error))
          .to eq("ToolContractsSpec::Valid has an invalid tool contract — the stored message")
      }
    end

    # An exception whose class owns `#exception` is not renamed at all — because renaming ends in `raise`, which
    # dispatches the 0-arg `#exception` on the object it is handed, and no guard can wrap that. Having been raised
    # once says nothing about the second call: this override answers itself the first time and raises the second,
    # and `Exception#exception(message)` clones, so `raise` asks the CLONE. Reported as axn's own error, which
    # keeps the tool name and the message and carries the original as `cause`.
    it "reports an #exception override as axn's own error rather than renaming it" do
      hostile = Class.new(ArgumentError) do
        def initialize(*)
          @calls = 0
          super
        end

        def exception(*_args)
          @calls += 1
          raise NotImplementedError, "second call" if @calls > 1

          self
        end
      end
      raising_from(hostile, hostile.new("the real defect"))

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |error|
        expect(error.message).to start_with("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        expect(error.cause).to be_a(hostile)
      }
    end

    # A duplication hook is reached by the clone `Exception#exception(message)` makes, so an exception that owns
    # one is not cloned either — the hook is never run, and the tool name survives (where reporting the original
    # unrenamed would have lost it).
    it "reports one that owns a duplication hook as axn's own error, naming the tool" do
      hostile = Class.new(ArgumentError) do
        def initialize_copy(other) = raise(NotImplementedError, "hostile copy")
      end
      raising_from(hostile, hostile.new("the real defect"))

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |error|
        expect(error.message).to start_with("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        expect(error.cause).to be_a(hostile)
      }
    end

    # The ownership test asks the OBJECT here, not the class, because `clone` copies the singleton class onto the
    # copy and `raise` then dispatches `#exception` on it — so a singleton override IS code the reporting path
    # would run. (The container check one layer over asks the class, since `dup` carries no singleton.)
    it "reports one whose SINGLETON defines #exception as axn's own error" do
      hostile = Class.new(ArgumentError)
      error = hostile.new("the real defect")
      # Answers the 0-arg call `raise` makes with itself, so it can BE raised and reach the reporting path, and
      # substitutes only when handed a message.
      error.define_singleton_method(:exception) { |*args| args.empty? ? self : RuntimeError.new("substituted") }
      raising_from(hostile, error)

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |raised|
        expect(raised.message).to start_with("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        expect(raised.cause).to be(error)
      }
    end

    # The other direction of the same question: not an `#exception` that ANSWERS wrongly, but one that is GONE by
    # the time ownership is asked. `raise <instance>` dispatches the 0-arg `#exception` on the object, so an
    # `#exception` that removes itself while answering leaves the exception with no such method — and looking up
    # an owner for a method that does not exist raises `NameError`, from inside the reporting path, which is the
    # third exception this whole path exists to prevent. Absence answers "not native", so axn's own error is
    # reported exactly as it is for an exception that owns too much.
    #
    # The INSTANCE form is essential and is why a first attempt at this looks like a false positive: `raise
    # <Class>, msg` calls the CLASS's `exception`, never the instance's, so the singleton is never touched.
    it "reports one whose #exception undefines itself during the raise as axn's own error" do
      hostile = Class.new(ArgumentError) do
        def exception(*)
          singleton_class.send(:undef_method, :exception)
          self
        end
      end
      error = hostile.new("the real defect")
      raising_from(hostile, error)

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |raised|
        expect(raised.message).to start_with("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        expect(raised.cause).to be(error)
      }
    end

    # A FROZEN exception owns nothing at all and still cannot be renamed: `clone` preserves frozen state, so
    # storing the new message on the copy raises FrozenError from inside the reporting path.
    it "reports a frozen exception as axn's own error" do
      hostile = Class.new(ArgumentError)
      raising_from(hostile, hostile.new("the real defect").freeze)

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |error|
        expect(error.message).to start_with("ToolContractsSpec::Valid has an invalid tool contract — the real defect")
        expect(error.cause).to be_a(hostile)
      }
    end

    # Every rung above is about an exception's own CODE. This one is about the bytes it hands back while behaving
    # perfectly: axn's messages are UTF-8, and joining a String that has no UTF-8-compatible rendering to one
    # raises Encoding::CompatibilityError from the interpolation — so the contract failure was destroyed at boot,
    # by a path the guards around every dispatch cover completely, and the tool name went with it.
    #
    # Nothing hostile is needed to reach it: the message an ordinary `raise` stores is a String the raiser chose.
    describe "an exception whose message holds bytes a UTF-8 message cannot carry" do
      def binary = "bad\xFF".dup.force_encoding("ASCII-8BIT")
      def latin1 = "caf\xE9 broke".dup.force_encoding("ISO-8859-1")

      def be_readable_utf8
        satisfy("be readable UTF-8") { |message| message.encoding == Encoding::UTF_8 && message.valid_encoding? }
      end

      # The bytes are ESCAPED rather than scrubbed or dropped: the author still needs to see what the message
      # held, and `String#inspect` is the same escape every unrenderable NAME is reported by.
      it "reports one whose #message returns them, keeping its class and escaping the bytes" do
        hostile = Class.new(ArgumentError) { define_method(:message) { "bad\xFF".dup.force_encoding("ASCII-8BIT") } }
        raising_from(hostile, hostile.new("stored"))

        expect { Axn::Tools.validate_contracts! }.to raise_error(hostile) { |error|
          message = Exception.instance_method(:to_s).bind_call(error)
          expect(message).to eq('ToolContractsSpec::Valid has an invalid tool contract — "bad\xFF"')
          expect(message).to be_readable_utf8
          expect(error.cause).to be_a(hostile)
        }
      end

      # No override at all — the stored message of a plain ArgumentError. This is the shape most likely to happen
      # for real (a message built from a filesystem path, a database blob, or an external library's bytes).
      it "reports a plain exception whose STORED message holds them" do
        raising_from(Class.new(ArgumentError), ArgumentError.new(binary))

        expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
          expect(Exception.instance_method(:to_s).bind_call(error))
            .to eq('ToolContractsSpec::Valid has an invalid tool contract — "bad\xFF"')
        }
      end

      # Renderable bytes in another encoding are RENDERED, not escaped: a valid ISO-8859-1 message transcodes to
      # the same text, so the author reads their own words rather than a byte dump. (This also raised before.)
      it "renders a message in another encoding as its text" do
        raising_from(Class.new(ArgumentError), ArgumentError.new(latin1))

        expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
          message = Exception.instance_method(:to_s).bind_call(error)
          expect(message).to eq("ToolContractsSpec::Valid has an invalid tool contract — café broke")
          expect(message).to be_readable_utf8
        }
      end

      # Legitimate non-ASCII is not mangled — the rendering only ever fixes what an encoder could not carry.
      it "leaves a valid multibyte UTF-8 message exactly as it was" do
        raising_from(Class.new(ArgumentError), ArgumentError.new("café broke"))

        expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
          expect(Exception.instance_method(:to_s).bind_call(error))
            .to eq("ToolContractsSpec::Valid has an invalid tool contract — café broke")
        }
      end

      # The other branch builds its text in `InvalidContract#initialize`, so it needs the same treatment: an
      # exception with BOTH an owned `#exception` and unrenderable message bytes lands there.
      it "renders them on the InvalidContract branch too" do
        hostile = Class.new(ArgumentError) do
          def exception(*_args) = self
          define_method(:message) { "bad\xFF".dup.force_encoding("ASCII-8BIT") }
        end
        raising_from(hostile, hostile.new("stored"))

        expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |error|
          expect(error.message).to start_with('ToolContractsSpec::Valid has an invalid tool contract — "bad\xFF"')
          expect(error.message).to be_readable_utf8
          expect(error.cause).to be_a(hostile)
        }
      end

      # The fallback error renders its OWN inputs rather than trusting the caller to have rendered them: it is a
      # public exception class, and the setup path needs the same text for its other branch, so both render and
      # rendering is idempotent. Asserted directly, because through the setup path the reporter has already
      # rendered everything this error receives — the guarantee it makes is for any caller.
      it "renders its inputs when Axn::Tools::InvalidContract is built directly" do
        error = Axn::Tools::InvalidContract.new(tool: binary, reason: latin1, original_class: binary)

        expect(error.message).to be_readable_utf8
        expect(error.message).to start_with('"bad\xFF" has an invalid tool contract — café broke')
      end

      # Being a public class means the kwargs are filled in by callers who did not write the message path, and a
      # Symbol naming the tool is the obvious thing to pass — so the type is tested before the bytes are rendered.
      # Rendering alone is String-only (it binds String methods), which would make naming a tool by Symbol raise a
      # TypeError out of the very error meant to report the contract.
      it "tolerates a Symbol, which is the obvious way to name a tool" do
        error = Axn::Tools::InvalidContract.new(tool: :foo, reason: "bad", original_class: "ArgumentError")

        expect(error.message).to start_with("foo has an invalid tool contract — bad")
      end

      # A Symbol's bytes are as foreign as a String's — `const_set` accepts non-UTF-8 ones — so the Symbol branch
      # renders after converting rather than joining what `to_s` hands back.
      it "renders a Symbol whose bytes have no UTF-8 rendering" do
        error = Axn::Tools::InvalidContract.new(tool: "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym,
                                                reason: "bad", original_class: "ArgumentError")

        expect(error.message).to be_readable_utf8
        expect(error.message).to start_with('"bad\xFF" has an invalid tool contract')
      end

      # Anything else is named by its CLASS, which is legible and cannot raise. Dispatching `to_s` on an arbitrary
      # object is what this message path must never do — the object is the caller's, and the whole point of the
      # class is that reporting a contract failure does not become a second failure.
      it "names an unrenderable object by its class rather than dispatching its to_s" do
        hostile = Object.new.tap { |o| o.define_singleton_method(:to_s) { raise NotImplementedError, "to_s explodes" } }

        error = Axn::Tools::InvalidContract.new(tool: hostile, reason: "bad", original_class: "ArgumentError")

        expect(error.message).to start_with("Object has an invalid tool contract — bad")
      end

      # The TOOL's own name is foreign text on the same terms: a constant may hold non-UTF-8 bytes (`const_set`
      # accepts them, and `Module#to_s` hands them back), so naming the tool could destroy the report it exists
      # to improve. Rendered like everything else — a valid ISO-8859-1 constant reads as its text.
      it "renders a tool whose own constant holds non-UTF-8 bytes" do
        # Set directly rather than through `stub_const`, which parses its name argument as UTF-8 text.
        exotic = "Caf\xE9Tool".dup.force_encoding("ISO-8859-1").to_sym
        Axn::Tools.register_adapter(:mcp)
        klass = Class.new do
          include Axn
          tool :mcp
          expects :a, optional: true
          def call; end
        end
        Object.const_set(exotic, klass)
        allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).and_call_original
        allow(Axn::Internal::Reflection::PropertyNames).to receive(:validate_inbound!).with(klass).and_raise(ArgumentError, "the real defect")

        expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
          message = Exception.instance_method(:to_s).bind_call(error)
          expect(message).to eq("CaféTool has an invalid tool contract — the real defect")
          expect(message).to be_readable_utf8
        }
      ensure
        Object.send(:remove_const, exotic) if exotic && Object.const_defined?(exotic)
      end
    end

    # The fallback error is itself reportable without running anything: it stores its message rather than building
    # it in `#message`, so a bound `Exception#to_s` renders the same text.
    it "renders the fallback error's full text through a bound Exception#to_s" do
      hostile = Class.new(ArgumentError) { def exception(*_args) = self }
      raising_from(hostile, hostile.new("the real defect"))

      expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::Tools::InvalidContract) { |error|
        expect(Exception.instance_method(:to_s).bind_call(error)).to eq(error.message)
        expect(error.message).to include("axn does not run an exception's own code")
      }
    end
  end

  # An unrenderable name raises ArgumentError rather than a ContractViolation, so both families have to be
  # wrapped or one of them would reach boot unnamed.
  it "names the offending class for an unrenderable name too" do
    Axn::Tools.register_adapter(:mcp)
    bad = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym
    stub_const("ToolContractsSpec::Unrenderable", Class.new do
      include Axn
      tool :mcp
      expects(:payload, type: Hash) { field bad, type: String }
      def call; end
    end)

    expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
      expect(error.message).to start_with("ToolContractsSpec::Unrenderable has an invalid tool contract")
      expect(error.message).to include("bytes that have no UTF-8 rendering")
    }
  end

  # The third rule of the three, and the one a tool needs setup to catch most: a name that renders through code of
  # its own means the property axn judged and the property `JSON.generate` emits need not be the same, so the
  # definition an adapter hands a model can carry a property the contract does not have. Reachable only through an
  # assigned config, which is exactly what an adapter base or a generator may build.
  it "names the offending class for a name that decides its own rendering" do
    Axn::Tools.register_adapter(:mcp)
    masq = Class.new(String) { def to_s = "dup" }.new("other")
    stub_const("ToolContractsSpec::OwnRendering", Class.new do
      include Axn
      tool :mcp
      def call; end
    end)
    ToolContractsSpec::OwnRendering.internal_field_configs =
      [Axn::Core::Contract::FieldConfig.new(field: masq, reader_as: :held, validations: { allow_nil: true })].freeze

    expect { Axn::Tools.validate_contracts! }.to raise_error(ArgumentError) { |error|
      expect(error.message).to start_with("ToolContractsSpec::OwnRendering has an invalid tool contract")
      expect(error.message).to include("does not render through Ruby's own `to_s`")
    }
  end

  it "passes over valid tools" do
    Axn::Tools.register_adapter(:mcp)
    valid_tool

    expect { Axn::Tools.validate_contracts! }.not_to raise_error
  end

  # The point of running at setup: without it the same contract reaches an adapter, and the error surfaces from
  # whatever first projects — which for a tool is a model-facing call.
  it "leaves the same error to first projection when never called" do
    Axn::Tools.register_adapter(:mcp)
    klass = colliding_tool

    expect { klass.input_schema }.to raise_error(Axn::ContractViolation::DuplicateFieldError)
  end

  # Validation is adapter-agnostic, so a tool registered for two adapters is projected once rather than once per
  # adapter. Counted at the walk, since the memo is what makes the second projection free.
  it "validates each tool once regardless of how many adapters claim it" do
    Axn::Tools.register_adapter(:mcp)
    Axn::Tools.register_adapter(:ruby_llm)
    tool = valid_tool(adapters: %i[mcp ruby_llm])
    # Counted on the TARGET class rather than globally: the registry is process-global, so another spec file's
    # named tool class may legitimately still be enumerable and would inflate a global count.
    # Counted at the BUILD rather than at `input_schema`: setup validates axn's own projection directly, since
    # `input_schema` may belong to an adapter base class (see the shadowing example below).
    projections = 0
    allow(Axn::Internal::Reflection::Schema).to receive(:build_input_for).and_wrap_original do |original, klass|
      projections += 1 if klass == tool
      original.call(klass)
    end

    Axn::Tools.validate_contracts!

    expect(projections).to eq(1)
  end

  it "does not project non-tool axns" do
    Axn::Tools.register_adapter(:mcp)
    latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
    stub_const("ToolContractsSpec::NotATool", Class.new do
      include Axn
      expects(:payload, type: Hash) do
        field :café, type: String
        field latin1, type: Integer
      end
      def call; end
    end)

    expect { Axn::Tools.validate_contracts! }.not_to raise_error
  end

  # A second setup pass (a dev reload calls the entry point again) must stay silent for a valid contract and stay
  # loud for an invalid one — a memo that swallowed the second would hide it from every reload after the first.
  it "keeps raising across repeated setup passes" do
    Axn::Tools.register_adapter(:mcp)
    colliding_tool

    expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::ContractViolation::DuplicateFieldError)
    expect { Axn::Tools.validate_contracts! }.to raise_error(Axn::ContractViolation::DuplicateFieldError)
  end

  # The width of the guarantee, pinned: membership is the union of a directory grant and a DECLARATION grant, so
  # a `tool`-DSL axn is enumerated with no tool root configured at all. What bounds coverage is whether the class
  # is LOADED and whether any adapter is registered — not whether it lives in a directory.
  describe "what enumeration covers" do
    it "enumerates a declaration-granted tool with no tool roots configured" do
      Axn::Tools.register_adapter(:mcp)
      tool = valid_tool

      expect(Axn::Tools::Registry.send(:_all_adapter_dirs)).to be_empty
      expect(Axn::Tools::Registry.tool_classes).to include(tool)
    end

    # The local is NOT named `tool`: bare `tool` inside the class body would then parse as that local variable
    # (nil at that point) instead of the DSL method, and the fixture would declare no tool at all.
    it "enumerates a tool declared for every adapter (bare `tool`)" do
      Axn::Tools.register_adapter(:mcp)
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
      expect { Axn::Tools.validate_contracts! }.not_to raise_error
    end
  end

  describe "Registry.tool_classes" do
    # The registry is process-global, so this asserts membership rather than an exact set: another spec's named
    # tool class may legitimately still be defined.
    it "enumerates tools independent of members" do
      Axn::Tools.register_adapter(:mcp)
      tool = valid_tool
      plain = stub_const("ToolContractsSpec::Plain", Class.new { include Axn })

      classes = Axn::Tools::Registry.tool_classes

      expect(classes).to include(tool)
      expect(classes).not_to include(plain)
    end
  end
end
