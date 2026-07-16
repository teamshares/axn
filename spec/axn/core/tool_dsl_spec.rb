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
end
