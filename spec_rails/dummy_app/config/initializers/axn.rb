# frozen_string_literal: true

# Configure Axn for testing with Actions namespace
Axn.configure do |c|
  c.rails.app_actions_autoload_namespace = :Actions
end

# Ensure the Axn Rails engine is loaded
# This is needed because the engine is only conditionally required in axn.rb
require "axn/rails/engine"

# Manually implement the engine's initializer logic since the engine isn't auto-registered
# This is what the engine would do if it were properly registered
actions_path = ::Rails.application.root.join("app/actions")

# Only add if the directory exists
if File.directory?(actions_path)
  # Use modern Rails autoloader API (Rails 7.2+)
  # Namespace is configurable via Axn.config.rails.app_actions_autoload_namespace
  autoload_namespace = Axn.config.rails.app_actions_autoload_namespace

  if autoload_namespace
    # Create the namespace module if it doesn't exist
    namespace = Object.const_get(autoload_namespace) if Object.const_defined?(autoload_namespace)
    unless namespace
      namespace = Module.new
      Object.const_set(autoload_namespace, namespace)
    end
    ::Rails.autoloaders.main.push_dir(actions_path, namespace:)
  else
    # No namespace - load directly
    ::Rails.autoloaders.main.push_dir(actions_path)
  end
end
