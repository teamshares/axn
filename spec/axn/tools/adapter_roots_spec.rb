# frozen_string_literal: true

RSpec.describe Axn::Tools::AdapterRoots do
  def build_source
    Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
  end

  it "defaults tool_roots to an empty array" do
    expect(build_source.config.tool_roots).to eq([])
  end

  it "accepts a narrow list of string roots" do
    source = build_source
    source.config.tool_roots = %w[agent_tools actions/tools]
    expect(source.config.tool_roots).to eq(%w[agent_tools actions/tools])
  end

  it "rejects a non-array value" do
    expect { build_source.config.tool_roots = "agent_tools" }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a non-string entry" do
    expect { build_source.config.tool_roots = [:agent_tools] }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a broad entry (bare actions dir)" do
    expect { build_source.config.tool_roots = %w[actions] }
      .to raise_error(ArgumentError, /too broad/)
  end

  it "rejects a `..` traversal entry" do
    expect { build_source.config.tool_roots = %w[../secrets] }
      .to raise_error(ArgumentError, /too broad/)
  end
end
