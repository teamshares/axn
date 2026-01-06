# frozen_string_literal: true

module Axn
  class RailsConfiguration
    attr_accessor :app_actions_autoload_namespace
  end

  class Configuration
    attr_accessor :emit_metrics, :raise_piping_errors_outside_production
    attr_writer :logger, :env, :on_exception, :additional_includes, :log_level, :rails

    def log_level = @log_level ||= :info

    def additional_includes = @additional_includes ||= []

    def _default_async_adapter = @default_async_adapter ||= false
    def _default_async_config = @default_async_config ||= {}
    def _default_async_config_block = @default_async_config_block

    def set_default_async(adapter = false, **config, &block) # rubocop:disable Style/OptionalBooleanParameter
      raise ArgumentError, "Cannot set default async adapter to nil as it would cause infinite recursion" if adapter.nil?

      @default_async_adapter = adapter unless adapter.nil?
      @default_async_config = config.any? ? config : {}
      @default_async_config_block = block_given? ? block : nil
    end

    def rails = @rails ||= RailsConfiguration.new

    def on_exception(e, action:, context: {})
      msg = "Handled exception (#{e.class.name}): #{e.message}"
      msg = ("#" * 10) + " #{msg} " + ("#" * 10) unless Axn.config.env.production?
      action.log(msg)

      return unless @on_exception

      # Only pass the args and kwargs that the given block expects
      Axn::Util::Callable.call_with_desired_shape(@on_exception, args: [e], kwargs: { action:, context: })
    end

    def logger
      @logger ||= begin
        # Use sidekiq logger if in background
        if Axn::Util::BackgroundJob.running_in_background? && defined?(Sidekiq)
          Sidekiq.logger
        else
          Rails.logger
        end
      rescue NameError
        Logger.new($stdout).tap do |l|
          l.level = Logger::INFO
        end
      end
    end

    def env
      @env ||= ENV["RACK_ENV"].presence || ENV["RAILS_ENV"].presence || "development"
      ActiveSupport::StringInquirer.new(@env)
    end
  end

  class << self
    def config = @config ||= Configuration.new

    def configure
      self.config ||= Configuration.new
      yield(config) if block_given?
    end
  end
end
