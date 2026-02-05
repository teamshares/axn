# frozen_string_literal: true

module Axn
  class RailsConfiguration
    attr_accessor :app_actions_autoload_namespace
  end

  class Configuration
    attr_accessor :emit_metrics, :raise_piping_errors_in_dev
    attr_writer :logger, :env, :on_exception, :additional_includes, :log_level, :rails

    # Controls when on_exception is triggered in async context (Sidekiq/ActiveJob).
    # Options:
    #   :every_attempt - trigger on every retry attempt (includes retry context)
    #   :first_and_exhausted - trigger on first attempt and when retries exhausted (default)
    #   :only_exhausted - only trigger when retries exhausted (via death handler)
    ASYNC_EXCEPTION_REPORTING_OPTIONS = %i[every_attempt first_and_exhausted only_exhausted].freeze

    def async_exception_reporting
      @async_exception_reporting ||= :first_and_exhausted
    end

    def async_exception_reporting=(value)
      unless ASYNC_EXCEPTION_REPORTING_OPTIONS.include?(value)
        raise ArgumentError, "async_exception_reporting must be one of: #{ASYNC_EXCEPTION_REPORTING_OPTIONS.join(', ')}"
      end

      @async_exception_reporting = value

      # Auto-register Sidekiq middleware/death handler if needed and Sidekiq is available
      _auto_configure_sidekiq_for_async_exception_reporting(value)
    end

    # Optional override for max retries across all async jobs.
    # When nil (default), each adapter uses its own default (Sidekiq: 25, ActiveJob: 5).
    # When explicitly set, this value overrides the adapter's default for retry context tracking.
    attr_accessor :async_max_retries

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

      _ensure_async_exception_reporting_registered_for_adapter(adapter)
      _apply_async_to_enqueue_all_orchestrator
    end

    # Async configuration for EnqueueAllOrchestrator (used by enqueue_all_async)
    # Defaults to the default async config if not explicitly set
    def _enqueue_all_async_adapter = @enqueue_all_async_adapter || _default_async_adapter
    def _enqueue_all_async_config = @enqueue_all_async_config || _default_async_config
    def _enqueue_all_async_config_block = @enqueue_all_async_config_block || _default_async_config_block

    def set_enqueue_all_async(adapter, **config, &block)
      @enqueue_all_async_adapter = adapter
      @enqueue_all_async_config = config.any? ? config : {}
      @enqueue_all_async_config_block = block_given? ? block : nil

      _ensure_async_exception_reporting_registered_for_adapter(adapter)
      _apply_async_to_enqueue_all_orchestrator
    end

    def rails = @rails ||= RailsConfiguration.new

    def on_exception(e, action:, context: {})
      if action.respond_to?(:result) && action.result.respond_to?(:error)
        resolved_error = action.result.error
        # Compare with the default fallback message instead of calling default_error
        # to avoid triggering error message resolution multiple times
        detail = resolved_error == Axn::Core::Flow::Handlers::Resolvers::MessageResolver::DEFAULT_ERROR ? e.message : resolved_error
      else
        detail = e.message
      end

      msg = "Handled exception (#{e.class.name}): #{detail}"
      msg = ("#" * 10) + " #{msg} " + ("#" * 10) unless Axn.config.env.production?
      action.log(msg)

      return unless @on_exception

      # Only pass the args and kwargs that the given block expects
      Axn::Util::Callable.call_with_desired_shape(@on_exception, args: [e], kwargs: { action:, context: })
    end

    def logger
      @logger ||= begin
        # Use sidekiq logger if in background
        if Axn::Util::ExecutionContext.background? && defined?(Sidekiq)
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

    private

    # Apply async config to EnqueueAllOrchestrator if it's already loaded.
    # Called from set_default_async and set_enqueue_all_async to ensure the
    # orchestrator has Sidekiq::Job included before any worker tries to process jobs.
    def _apply_async_to_enqueue_all_orchestrator
      return unless defined?(Axn::Async::EnqueueAllOrchestrator)

      adapter = _enqueue_all_async_adapter
      return if adapter.nil? || adapter == false

      Axn::Async::EnqueueAllOrchestrator.async(
        adapter,
        **_enqueue_all_async_config,
        &_enqueue_all_async_config_block
      )
    end

    # Ensures the given async adapter has exception-reporting components registered
    # for the current async_exception_reporting mode (e.g. Sidekiq middleware/death handler).
    # Called when setting default or enqueue_all async adapter so the default mode works
    # without the app having to set async_exception_reporting explicitly.
    def _ensure_async_exception_reporting_registered_for_adapter(adapter)
      return if adapter.nil? || adapter == false

      case adapter
      when :sidekiq
        _auto_configure_sidekiq_for_async_exception_reporting(async_exception_reporting)
      end
      # Active Job has no global registration (per-class proxy with after_discard).
    end

    # Auto-configures Sidekiq middleware and death handler when async_exception_reporting
    # is set to a mode that requires them.
    #
    # This registers if Sidekiq is available. The middleware and death handler
    # are no-ops for non-Axn jobs (they check if the worker includes Axn::Core),
    # so it's safe to register even if some actions use ActiveJob instead.
    #
    # Note: ActiveJob with Sidekiq backend uses ActiveJob's own `executions`
    # counter for retry tracking, not this middleware.
    def _auto_configure_sidekiq_for_async_exception_reporting(mode)
      return unless defined?(::Sidekiq)
      return if mode == :every_attempt # No special requirements for this mode

      # Require the auto_configure module (lazy load to avoid circular deps)
      require "axn/async/adapters/sidekiq/auto_configure"

      # Auto-register the required components
      Axn::Async::Adapters::Sidekiq::AutoConfigure.register!
    rescue LoadError
      # Sidekiq adapter files not available - user will need to configure manually
      nil
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
