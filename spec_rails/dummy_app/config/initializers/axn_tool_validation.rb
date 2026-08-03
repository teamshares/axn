# frozen_string_literal: true

# Registers a tool adapter with a real tool root so the app exercises axn's setup-time contract validation
# end-to-end: without a registered adapter there are no tool roots, nothing is enumerable, and
# `Axn::Tools.validate_contracts!` would validate nothing at all.
#
# The root is `actions/boot_validated`, NOT `actions/tools` — SampleWidget there must stay unloaded at boot so
# tools_eager_load_spec can still prove on-demand loading.
#
# Registration only; the directory is loaded later, at `after_initialize`, which is after the engine has pushed
# app/actions onto the autoloader.
boot_check_source = Module.new do
  extend Axn::Configurable
  extend Axn::Tools::AdapterRoots
end
boot_check_source.config.tool_roots = %w[actions/boot_validated]

Axn::Tools.register_adapter(:boot_check, boot_check_source)
