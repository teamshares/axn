# frozen_string_literal: true

RSpec.describe "Axn tool registry under Rails" do
  around do |example|
    original = Axn.config.tool_paths
    Axn.config.tool_paths = %w[actions/tools]
    Axn::Tools::Registry.reset_adapters!
    Axn.register_tool_adapter(:mcp)
    example.run
  ensure
    Axn.config.tool_paths = original
    Axn::Tools::Registry.reset_adapters!
  end

  # The dummy app namespaces app/actions under `Actions` (see
  # config/initializers/axn.rb -> app_actions_autoload_namespace = :Actions), so the
  # fixture at app/actions/tools/sample_widget.rb autoloads as Actions::Tools::SampleWidget.
  it "eager-loads the tool_paths dir on demand and finds the tool without referencing it first" do
    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  it "derives a clean tool_name (stripping the `actions`/`tools` namespace prefixes)" do
    Axn.tools_for(:mcp)
    expect(Actions::Tools::SampleWidget.tool_name).to eq("sample_widget")
  end
end
