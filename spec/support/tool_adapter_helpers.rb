# frozen_string_literal: true

module ToolAdapterHelpers
  # Registers `key` with a real config source (an anonymous module carrying a validated
  # `tool_roots` list plus the shared `reject_opaque_exposed_values` declaration/resolve/render
  # chain), so registry directory-grant tests exercise the production read path
  # (`source.config.tool_roots`) rather than stubbing it, and a spec exercising per-tool
  # serialization resolution has a real adapter fixture to reach for instead of hand-rolling one.
  def register_adapter_with_roots(key, roots: [], reject_opaque_default: false)
    source = Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
      extend Axn::Tools::AdapterSerialization
      declare_reject_opaque_exposed_values!(default: reject_opaque_default)
    end
    source.config.tool_roots = roots
    Axn::Tools.register_adapter(key, source)
    source
  end
end

RSpec.configure { |config| config.include ToolAdapterHelpers }
