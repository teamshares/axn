# frozen_string_literal: true

RSpec.describe "Axn `tool` DSL" do
  def axn(&blk) = Class.new { include Axn }.tap { |k| k.class_eval(&blk) if blk }

  it "bare `tool` declares membership in all adapters" do
    expect(axn { tool }._tool_declaration).to eq(:all)
  end

  it "`tool false` opts out" do
    expect(axn { tool false }._tool_declaration).to eq(false)
  end

  it "`tool :mcp` declares an explicit single-adapter set" do
    expect(axn { tool :mcp }._tool_declaration).to eq([:mcp])
  end

  it "`tool :mcp, :ruby_llm` declares an explicit multi-adapter set" do
    expect(axn { tool :mcp, :ruby_llm }._tool_declaration).to eq(%i[mcp ruby_llm])
  end

  it "`tool name:` sets the override and declares all adapters" do
    k = axn { tool name: "custom_name" }
    expect(k._tool_declaration).to eq(:all)
    expect(k.tool_name).to eq("custom_name")
  end

  it "`tool :mcp, name:` composes an adapter set with a name override" do
    k = axn { tool :mcp, name: "custom_name" }
    expect(k._tool_declaration).to eq([:mcp])
    expect(k.tool_name).to eq("custom_name")
  end

  it "rejects `tool false` combined with a name override" do
    expect { axn { tool false, name: "x" } }.to raise_error(ArgumentError, /opts out/)
  end

  it "rejects `tool false` combined with an adapter" do
    expect { axn { tool :mcp, false } }.to raise_error(ArgumentError, /opts out/)
  end

  it "rejects a non-Symbol adapter" do
    expect { axn { tool "mcp" } }.to raise_error(ArgumentError, /must be Symbols/)
  end

  it "rejects a name that sanitizes to empty (no provider-safe characters)" do
    expect { axn { tool name: "!!!" } }.to raise_error(ArgumentError, /provider-safe/)
  end

  it "rejects a whitespace-only name" do
    expect { axn { tool name: "  " } }.to raise_error(ArgumentError, /provider-safe/)
  end

  it "rejects an empty-string name" do
    expect { axn { tool name: "" } }.to raise_error(ArgumentError, /provider-safe/)
  end

  it "still accepts a name with at least one provider-safe character" do
    expect(axn { tool name: "custom_name" }.tool_name).to eq("custom_name")
  end

  it "inherits the declaration to subclasses" do
    parent = axn { tool :mcp }
    expect(Class.new(parent)._tool_declaration).to eq([:mcp])
  end

  describe "rejecting a repeated `tool` declaration on the same class" do
    it "raises when `tool :mcp` is followed by `tool :ruby_llm`" do
      expect do
        axn do
          tool :mcp
          tool :ruby_llm
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "raises when `tool` is followed by `tool name:`" do
      expect do
        axn do
          tool
          tool name: "x"
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "raises when `tool false` is followed by `tool :mcp`" do
      expect do
        axn do
          tool false
          tool :mcp
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "raises when `tool :mcp` is followed by `tool false`" do
      expect do
        axn do
          tool :mcp
          tool false
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "still accepts a single combined `tool :mcp, :ruby_llm, name:` call" do
      k = axn { tool :mcp, :ruby_llm, name: "combined" }
      expect(k._tool_declaration).to eq(%i[mcp ruby_llm])
      expect(k.tool_name).to eq("combined")
    end

    it "does NOT raise when a subclass declares `tool` after the parent declared `tool` (per-class, not inherited)" do
      parent = axn { tool :mcp }
      sub = nil
      expect { sub = Class.new(parent) { tool :ruby_llm } }.not_to raise_error
      expect(sub._tool_declaration).to eq([:ruby_llm])
    end

    it "a subclass whose parent declared `tool` can still declare `tool` once, but not twice" do
      parent = axn { tool :mcp }
      expect do
        Class.new(parent) do
          tool :ruby_llm
          tool :mcp
        end
      end.to raise_error(ArgumentError, /already declared/)
    end
  end

  describe "per-adapter option bags" do
    it "`tool mcp: {}` declares membership in that adapter" do
      expect(axn { tool mcp: {} }._tool_declaration).to eq([:mcp])
    end

    it "unions positional adapters and bag keys for membership" do
      k = axn { tool :ruby_llm, mcp: { present_as: :message } }
      expect(k._tool_declaration).to eq(%i[ruby_llm mcp])
    end

    it "allows a redundant positional adapter and bag for the same key" do
      expect(axn { tool :mcp, mcp: { present_as: :message } }._tool_declaration).to eq([:mcp])
    end

    it "rejects a non-Hash bag value" do
      expect { axn { tool mcp: :message } }.to raise_error(ArgumentError, /must be Hashes/)
    end

    it "rejects a non-Symbol bag adapter key (smuggled via a string-keyed splat), like positional adapters" do
      expect { axn { tool(**{ "mcp" => { present_as: :message } }) } }.to raise_error(ArgumentError, /must be Symbols/)
    end

    it "rejects `tool false` combined with a per-adapter bag" do
      expect { axn { tool false, mcp: { present_as: :message } } }.to raise_error(ArgumentError, /opts out/)
    end

    it "extends the repeated-`tool` guard to the bag form" do
      expect do
        axn do
          tool :mcp
          tool ruby_llm: {}
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "stores config tolerantly for an unregistered adapter and still declares membership" do
      k = axn { tool not_loaded: { anything: :x } }
      expect(k._tool_declaration).to eq([:not_loaded])
      slot = k.instance_variable_get(:@_axn_config_overrides)[:not_loaded]
      expect(slot).to eq(anything: :x)
    end

    describe "per-adapter name override" do
      it "overrides tool_name for that adapter only" do
        k = axn { tool mcp: { name: "search" }, ruby_llm: {} }
        expect(k.tool_name(:mcp)).to eq("search")
        expect(k.tool_name(:ruby_llm)).not_to eq("search")
      end

      it "falls back to the shared `tool name:` for an adapter without a per-adapter name" do
        k = axn { tool name: "shared", mcp: {} }
        expect(k.tool_name(:mcp)).to eq("shared")
      end

      it "leaves zero-arg tool_name (shared/derived) unaffected by a per-adapter name" do
        k = axn { tool mcp: { name: "search" } }
        expect(k.tool_name).to eq("tool") # anonymous class, no shared name -> derived default
      end

      it "rejects a per-adapter name that sanitizes to empty" do
        expect { axn { tool mcp: { name: "!!!" } } }.to raise_error(ArgumentError, /provider-safe/)
      end

      it "does not write the intercepted name into the config store" do
        k = axn { tool custom_adapter: { name: "search", foo: :bar } }
        slot = k.instance_variable_get(:@_axn_config_overrides)[:custom_adapter]
        expect(slot).to include(foo: :bar)
        expect(slot).not_to have_key(:name)
      end

      it "intercepts a string-keyed name too (does not leak into the config store)" do
        k = axn { tool custom_adapter: { "name" => "search", foo: :bar } }
        expect(k.tool_name(:custom_adapter)).to eq("search")
        slot = k.instance_variable_get(:@_axn_config_overrides)[:custom_adapter]
        expect(slot).to include(foo: :bar)
        expect(slot).not_to have_key(:name)
      end

      it "a subclass opting out via `tool false` does not inherit the parent's per-adapter name overrides" do
        parent = axn { tool mcp: { name: "search" } }
        sub = Class.new(parent) { tool false }
        expect(sub._tool_name_overrides).to eq({})
        expect(sub.tool_name(:mcp)).not_to eq("search")
      end
    end
  end

  describe "except: opt-out" do
    it "stores a single excepted adapter" do
      k = axn { tool except: :ruby_llm }
      expect(k._tool_except).to eq([:ruby_llm])
    end

    it "stores a list of excepted adapters" do
      k = axn { tool except: %i[ruby_llm openapi] }
      expect(k._tool_except).to eq(%i[ruby_llm openapi])
    end

    it "defaults _tool_except to an empty array when no except: is given" do
      expect(axn { tool :mcp }._tool_except).to eq([])
    end

    it "except:-only (no positional/bags) yields an empty-array declaration, not :all" do
      k = axn { tool except: :ruby_llm }
      expect(k._tool_declaration).to eq([])
    end

    it "bare `tool` is still :all (all adapters), distinct from except:-only" do
      expect(axn { tool }._tool_declaration).to eq(:all)
    end

    it "`tool name:` with no adapters is still :all" do
      expect(axn { tool name: "x" }._tool_declaration).to eq(:all)
    end

    it "`tool name:, except:` keeps the all-adapter grant (name: is a broad gesture), not directory-only" do
      k = axn { tool name: "search", except: :ruby_llm }
      expect(k._tool_declaration).to eq(:all)
      expect(k._tool_except).to eq([:ruby_llm])
    end

    it "a bare `except:` narrows the directory grant regardless of list emptiness (same base as a populated except:)" do
      expect(axn { tool except: [] }._tool_declaration).to eq([])
      expect(axn { tool except: :ruby_llm }._tool_declaration).to eq([])
    end

    it "composes positional adapters with except:" do
      k = axn { tool :mcp, :openapi, except: :openapi }
      expect(k._tool_declaration).to eq(%i[mcp openapi])
      expect(k._tool_except).to eq([:openapi])
    end

    it "rejects a non-Symbol except entry" do
      expect { axn { tool except: "mcp" } }.to raise_error(ArgumentError, /must be Symbols/)
    end

    it "rejects `tool false` combined with except:" do
      expect { axn { tool false, except: :mcp } }.to raise_error(ArgumentError, /opts out/)
    end

    it "clears an inherited _tool_except when a subclass redeclares tool" do
      parent = axn { tool except: :ruby_llm }
      child = Class.new(parent) { tool :mcp }
      expect(child._tool_except).to eq([])
    end
  end
end

RSpec.describe "Axn `tool` DSL — per-adapter bags write into the config store" do
  let(:mcp) do
    Module.new do
      extend Axn::Configurable
      config_namespace :mcp
      setting :present_as, default: :structured, one_of: %i[structured message], overridable: true
    end
  end

  def tool_class(overrides, &blk)
    Class.new do
      include Axn
      include overrides
      class_eval(&blk)
    end
  end

  it "resolves a bag key identically to configure(:mcp)" do
    klass = tool_class(mcp.overrides) { tool mcp: { present_as: :message } }
    expect(mcp.resolve_override_for(klass, :present_as)).to eq(:message)
  end

  it "validates an unknown key eagerly when the adapter's source is registered" do
    expect { tool_class(mcp.overrides) { tool mcp: { bogus: :x } } }
      .to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "validates a bad value eagerly when the adapter's source is registered" do
    expect { tool_class(mcp.overrides) { tool mcp: { present_as: :nonsense } } }
      .to raise_error(ArgumentError, /present_as/)
  end

  it "intercepts a string-keyed name for a registered adapter without treating it as a setting" do
    klass = tool_class(mcp.overrides) { tool mcp: { "name" => "search", present_as: :message } }
    expect(klass.tool_name(:mcp)).to eq("search")
    expect(mcp.resolve_override_for(klass, :present_as)).to eq(:message)
  end
end
