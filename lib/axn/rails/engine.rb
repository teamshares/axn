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
        # directory is automatically added to the autoload paths so that Rails can
        # automatically load the actions.
        initializer "axn.add_app_actions_to_autoload" do |app|
          actions_path = app.root.join("app/actions")

          # Only add if the directory exists
          return unless File.directory?(actions_path)

          # Add to autoload paths (works for all Rails versions)
          app.config.autoload_paths += [actions_path] unless app.config.autoload_paths.include?(actions_path)
          app.config.eager_load_paths += [actions_path] unless app.config.eager_load_paths.include?(actions_path)

          # Handle Rails 7.1+ changes to autoloading
          # In Rails 7.1+, autoload paths are no longer automatically added to $LOAD_PATH
          # This is generally fine for autoloading, but we can add it if needed for compatibility
          if ::Rails.version.to_f >= 7.1
            # Check if the app has explicitly enabled adding autoload paths to load path
            if app.config.respond_to?(:add_autoload_paths_to_load_path) &&
               app.config.add_autoload_paths_to_load_path == true && !$LOAD_PATH.include?(actions_path.to_s)
              $LOAD_PATH << actions_path.to_s
            end
          else # rubocop:disable Style/EmptyElse
            # For Rails < 7.1, autoload paths were automatically added to $LOAD_PATH
            # No additional action needed
          end
        end
      end
    end
  end
end
