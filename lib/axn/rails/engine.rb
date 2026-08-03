# frozen_string_literal: true

# Only define the Engine if Rails is available
if defined?(Rails) && Rails.const_defined?(:Engine)
  module Axn
    module RailsIntegration
      class Engine < Rails::Engine
        # Set a custom engine name that's more concise than the module path
        engine_name "axn_rails"

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
            Rails.autoloaders.main.push_dir(actions_path, namespace:)
          else
            # No namespace - load directly
            Rails.autoloaders.main.push_dir(actions_path)
          end
        end

        # Validate every tool axn's contract at app setup, so a colliding or unrenderable property name is a
        # boot failure rather than something a user's tool call discovers.
        #
        # `after_initialize`, NOT an initializer ordered after `load_config_initializers`: Rails' eager-load
        # phase runs late in boot, and Axn::Tools::Registry#ensure_loaded! deliberately defers to it (see the
        # comment there about `initialized?`). Hooking earlier would force every tool class to load before the
        # app's own initializers had run — changing load order for the sake of a check.
        #
        # `to_prepare` as well, and this is not redundant: Zeitwerk unloads on code change, so in development a
        # one-shot hook would validate only the first boot and every reload after it would go unchecked. It runs
        # once in production too, right after `after_initialize`, and the per-class memo makes the second pass
        # free.
        config.after_initialize { Axn::Tools.validate_contracts! }
        config.to_prepare { Axn::Tools.validate_contracts! }

        # Register the generator
        generators do
          require_relative "generators/axn_generator"
        end
      end
    end
  end
end
