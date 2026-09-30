# frozen_string_literal: true

# Empties the tool adapter registry for an example and restores it afterward, each adapter WITH its config source.
# The source is what carries an adapter's `tool_roots`: re-registering a bare key after a reset stores a nil source,
# which leaves the adapter listed but drops every directory-granted tool — for this app, the boot-registered
# `:boot_check` adapter that later specs assert on.
RSpec.shared_context "with an isolated tool adapter registry" do
  around do |example|
    registry = Axn::Tools::Registry
    sources = registry.adapters.to_h { |adapter| [adapter, registry.adapter_config_source(adapter)] }
    registry.reset_adapters!
    example.run
  ensure
    registry.reset_adapters!
    sources&.each { |adapter, source| Axn::Tools.register_adapter(adapter, source) }
  end
end
