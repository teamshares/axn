# frozen_string_literal: true

# Configure Axn for testing with Actions namespace
Axn.configure do |c|
  c.rails.app_actions_autoload_namespace = :Actions
end
