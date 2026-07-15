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

  it "inherits the declaration to subclasses" do
    parent = axn { tool :mcp }
    expect(Class.new(parent)._tool_declaration).to eq([:mcp])
  end
end
