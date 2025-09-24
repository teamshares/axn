# frozen_string_literal: true

# Only define the Engine if Rails is available
if defined?(Rails) && Rails.const_defined?(:Engine)
  module Axn
    module Rails
      class Engine < ::Rails::Engine
        # This engine is automatically loaded when AXN is used in a Rails context
        # It ensures proper initialization and integration with Rails

        # The engine is intentionally minimal - AXN is designed to work
        # as a standalone library that can be used in any Ruby context

        # However, when used alongside Rails, we ensure that the app/actions
        # directory is automatically added to the autoloader so that Rails can
        # automatically load the actions.
        initializer "axn.add_app_actions_to_autoload", after: :load_config_initializers do |app|
          actions_path = app.root.join("app/actions")

          # Only add if the directory exists
          next unless File.directory?(actions_path)

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

        # Register the generator
        generators do
          require_relative "generators/axn_generator"
        end
      end
    end
  end
end
