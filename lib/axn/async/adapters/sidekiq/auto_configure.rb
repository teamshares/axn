# frozen_string_literal: true

require_relative "middleware"
require_relative "death_handler"

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Auto-configures Sidekiq server middleware and death handlers for Axn.
        #
        # This is automatically called when you set Axn.config.async_exception_reporting
        # to a mode other than :every_attempt. You can also call it manually:
        #
        #   Axn::Async::Adapters::Sidekiq::AutoConfigure.register!
        #
        module AutoConfigure
          class << self
            def registered?
              @registered == true
            end

            def middleware_registered?
              @middleware_registered == true
            end

            def death_handler_registered?
              @death_handler_registered == true
            end

            # Registers both middleware and death handler.
            # Safe to call multiple times - will not duplicate registrations.
            def register!
              register_middleware!
              register_death_handler!
              @registered = true
            end

            # Registers just the middleware (for retry context tracking)
            def register_middleware!
              return if middleware_registered?
              return unless defined?(::Sidekiq)

              ::Sidekiq.configure_server do |config|
                config.server_middleware do |chain|
                  # Check if already added (in case of multiple configure_server calls)
                  already_added = chain.any? do |entry|
                    entry.klass == Middleware
                  rescue StandardError
                    false
                  end
                  chain.add Middleware unless already_added
                end
              end

              @middleware_registered = true
            end

            # Registers just the death handler (for exhausted retry reporting)
            def register_death_handler!
              return if death_handler_registered?
              return unless defined?(::Sidekiq)

              ::Sidekiq.configure_server do |config|
                config.death_handlers << DeathHandler unless config.death_handlers.include?(DeathHandler)
              end

              @death_handler_registered = true
            end

            # Validates that required components are registered for the given config mode.
            # Raises ConfigurationError with instructions if configuration is incomplete.
            #
            # Note: This checks whether register! was called, not whether Sidekiq
            # has actually loaded the middleware (which happens when server starts).
            def validate_configuration!(mode)
              return if mode == :every_attempt # No special requirements

              issues = []

              issues << "Sidekiq middleware not registered (required for retry context tracking)" unless middleware_registered?

              if %i[first_and_exhausted only_exhausted].include?(mode) && !death_handler_registered?
                issues << "Sidekiq death handler not registered (required for exhausted retry reporting)"
              end

              return if issues.empty?

              raise ConfigurationError, <<~MSG
                Axn async_exception_reporting is set to #{mode.inspect}, but Sidekiq is not fully configured:

                #{issues.map { |i| "  - #{i}" }.join("\n")}

                To fix, add this to your Sidekiq initializer (config/initializers/sidekiq.rb):

                  Axn::Async::Adapters::Sidekiq::AutoConfigure.register!

                Or manually configure:

                  Sidekiq.configure_server do |config|
                    config.server_middleware do |chain|
                      chain.add Axn::Async::Adapters::Sidekiq::Middleware
                    end
                    config.death_handlers << Axn::Async::Adapters::Sidekiq::DeathHandler
                  end
              MSG
            end

            # Reset state (for testing)
            def reset!
              @registered = false
              @middleware_registered = false
              @death_handler_registered = false
            end
          end
        end

        class ConfigurationError < StandardError; end
      end
    end
  end
end
