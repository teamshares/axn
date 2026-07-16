# frozen_string_literal: true

RSpec.describe "Axn tool registry under Rails" do
  around do |example|
    original_tool_paths = Axn.config.tool_paths
    original_adapters = Axn::Tools::Registry.adapters.dup

    Axn.config.tool_paths = %w[actions/tools]
    Axn::Tools::Registry.reset_adapters!
    Axn.register_tool_adapter(:mcp)

    example.run
  ensure
    Axn.config.tool_paths = original_tool_paths
    Axn::Tools::Registry.reset_adapters!
    original_adapters.each { |adapter| Axn.register_tool_adapter(adapter) }
  end

  # Force the on-demand `ensure_loaded! -> eager_load_dir` branch to run regardless of the
  # ambient CI env var: the dummy app sets `config.eager_load = ENV["CI"].present?`, so under
  # CI the whole app (including the fixture) is already eager-loaded at boot and `ensure_loaded!`
  # early-returns, making this spec pass vacuously. Stubbing eager_load to false here keeps the
  # test deterministic and meaningful in every environment. (Must be a `before`, not part of the
  # `around`'s pre-`example.run` setup: rspec-mocks isn't set up yet at that point.)
  before do
    allow(Rails.application.config).to receive(:eager_load).and_return(false)
  end

  # The dummy app namespaces app/actions under `Actions` (see
  # config/initializers/axn.rb -> app_actions_autoload_namespace = :Actions), so the
  # fixture at app/actions/tools/sample_widget.rb autoloads as Actions::Tools::SampleWidget.
  it "eager-loads the tool_paths dir on demand and finds the tool without referencing it first" do
    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  it "derives a clean tool_name (stripping the `actions`/`tools` namespace prefixes)" do
    Axn.tools_for(:mcp)
    expect(Actions::Tools::SampleWidget.tool_name).to eq("sample_widget")
  end

  it "resolves an app/-prefixed tool_paths entry to the same real dir as the bare spelling" do
    Axn.config.tool_paths = %w[app/actions/tools]

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  it "resolves a `.`-segment alternate spelling to the same real dir as the clean spelling" do
    Axn.config.tool_paths = %w[actions/./tools]

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end
end
