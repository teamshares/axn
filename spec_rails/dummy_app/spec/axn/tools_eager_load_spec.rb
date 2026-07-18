# frozen_string_literal: true

RSpec.describe "Axn tool registry under Rails" do
  around do |example|
    original_adapters = Axn::Tools::Registry.adapters.dup

    Axn::Tools::Registry.reset_adapters!

    example.run
  ensure
    Axn::Tools::Registry.reset_adapters!
    original_adapters.each { |adapter| Axn.register_tool_adapter(adapter) }
  end

  # Registers `:mcp` with a real config source (an anonymous module carrying a validated
  # `tool_roots` list), so the spec exercises the production read path
  # (`source.config.tool_roots`) rather than stubbing it. Stored on the example instance
  # (`@tool_source`) so individual examples below can reassign `tool_roots` to exercise
  # alternate path spellings.
  before do
    @tool_source = Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
    @tool_source.config.tool_roots = %w[actions/tools]
    Axn.register_tool_adapter(:mcp, @tool_source)
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
  it "eager-loads the tool_roots dir on demand and finds the tool without referencing it first" do
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

  it "resolves an app/-prefixed tool_roots entry to the same real dir as the bare spelling" do
    @tool_source.config.tool_roots = %w[app/actions/tools]

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  it "resolves an ABSOLUTE tool_roots entry directly instead of re-rooting it under app/" do
    @tool_source.config.tool_roots = [Rails.root.join("app/actions/tools").to_s]

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  it "resolves a `.`-segment alternate spelling to the same real dir as the clean spelling" do
    @tool_source.config.tool_roots = %w[actions/./tools]

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  # `config.eager_load = true` only means Rails INTENDS to eager-load; that phase runs late in
  # boot (after config/initializers). Simulates an adapter calling `Axn.tools_for` from within an
  # initializer, before `Rails.application.initialize!` has finished.
  it "still loads the tool dirs on demand when eager_load is true but the app hasn't finished initializing" do
    allow(Rails.application.config).to receive(:eager_load).and_return(true)
    allow(Rails.application).to receive(:initialized?).and_return(false)

    expect(Rails.autoloaders.main).to receive(:eager_load_dir)
      .with(Rails.root.join("app/actions/tools").to_s).and_call_original

    tools = Axn.tools_for(:mcp)

    expect(defined?(Actions::Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Actions::Tools::SampleWidget)
  end

  # Post-boot production steady state: eager-loading has already run, so the on-demand path
  # must be skipped as a fast path.
  it "skips the on-demand load when eager_load is true and the app has finished initializing" do
    allow(Rails.application.config).to receive(:eager_load).and_return(true)
    allow(Rails.application).to receive(:initialized?).and_return(true)

    expect(Rails.autoloaders.main).not_to receive(:eager_load_dir)

    Axn.tools_for(:mcp)
  end
end
