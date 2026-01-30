# frozen_string_literal: true

# Configure Axn for testing with Actions namespace
Axn.configure do |c|
  c.rails.app_actions_autoload_namespace = :Actions

  # Integration tests set this env var to configure the default adapter BEFORE actions load
  c.set_default_async(ENV["AXN_DEFAULT_ASYNC_ADAPTER"].to_sym) if ENV["AXN_DEFAULT_ASYNC_ADAPTER"].present?
end
