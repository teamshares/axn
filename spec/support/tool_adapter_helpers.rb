# frozen_string_literal: true

module ToolAdapterHelpers
  # Registers `key` with a real config source (an anonymous module carrying a validated
  # `tool_roots` list), so registry directory-grant tests exercise the production read path
  # (`source.config.tool_roots`) rather than stubbing it.
  def register_tool_adapter_with_roots(key, roots: [])
    source = Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
    source.config.tool_roots = roots
    Axn.register_tool_adapter(key, source)
    source
  end
end

RSpec.configure { |config| config.include ToolAdapterHelpers }
