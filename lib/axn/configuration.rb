# frozen_string_literal: true

require "axn/configurable"

module Axn
  class RailsConfiguration
    attr_accessor :app_actions_autoload_namespace
  end

  class Configuration
    extend Axn::Configurable::Settings

    # Axn's own overridable settings live under the `:core` namespace, so the no-arg
    # `configure { |c| … }` bag on an action reaches them (and never collides with an
    # adapter gem's namespaced settings).
    config_namespace :core

    # The live singleton whose values are the library-level fallback for any
    # `overridable: true` setting's per-class override accessors.
    overridable_config_source { Axn.config }

    # Simple value settings (defaults + validation) declared via the shared
    # Configurable kernel. Settings with global side effects, lazy/computed
    # values, or custom call semantics (env, logger, on_exception, the async
    # setters, async_exception_reporting, rails) remain hand-written below.
    setting :emit_metrics
    setting :raise_piping_errors_in_dev
    setting :log_level, default: :info
    setting :additional_includes, default: []

    # Optional override for max retries across all async jobs.
    # When nil (default), each adapter uses its own default (Sidekiq: 25, ActiveJob: 5).
    # When explicitly set, this value overrides the adapter's default for retry context tracking.
    setting :async_max_retries

    # Which declared facet types surface as Sidekiq per-job `tags` at enqueue (PRO-2855).
    # Sidekiq tags are ephemeral job-payload strings shown/searched in the web UI — they carry
    # no metrics-billing cost, so high-cardinality `tag`s are welcome here (unlike metrics).
    # Default is both; set %i[dimension] for bounded-only, or [] to disable the sink.
    SIDEKIQ_JOB_TAG_SOURCES = %i[tag dimension].freeze
    setting :sidekiq_job_tag_sources,
            default: %i[tag dimension],
            overridable: true,
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| SIDEKIQ_JOB_TAG_SOURCES.include?(s) } }

    # Declares an action (or, set globally, a whole app) as transport-facing: every top-level field
    # with a coercible declared type behaves as if it opted into `coerce:` (wire string → Ruby object
    # before validation), without annotating each field. The operational counterpart to the per-field
    # `coerce:` contract tool — for the common case of a controller/adapter handing an action a hash of
    # wire strings (see PRO-2884). Default false (strict): a global default-on would silently weaken
    # type strictness for in-process Ruby callers, for whom a String where a Date is declared is a bug.
    # A field's own `coerce:` always wins over this flag (explicit `coerce: false` opts back out).
    setting :coerce_input_types,
            default: false,
            overridable: true,
            validate: ->(v) { [true, false].include?(v) }

    # Dedicated directories whose Axns auto-register as tools (membership) and which core
    # eager-loads on demand to populate the registry. Security-sensitive and deliberately
    # narrow: it must never include a broad dir like bare `actions`, which would auto-expose
    # every business action. Resolved to `Rails.root/app/<path>` under Rails, else
    # `File.expand_path(<path>)`. Distinct from tool_name_stripped_prefixes (naming, cosmetic).
    # Validation for `tool_paths=` (including the broad-entry rejection) lives in the
    # hand-written writer below; the generated writer would only enforce the array-of-strings shape.
    setting :tool_paths,
            default: %w[agent_tools actions/tools]

    # Broad/root-like tool_path entries that must never be accepted: each resolves to a directory
    # holding EVERY business action (bare `actions` → `Rails.root/app/actions`, `app`/`.`/"" →
    # the app or project root), so auto-registering under them would expose the whole app as tools
    # and defeat the fail-safe guarantee. Compared against the normalized entry (see #tool_paths=).
    TOOL_PATHS_BLOCKLIST = ["", ".", "actions", "app", "app/actions"].freeze

    # Rejects broad/root-like entries at assignment with a message naming the offender, then stores
    # the (array-of-strings) value the generated reader/default expect. Narrow subdirs like
    # `agent_tools`, `actions/tools`, and `app/actions/tools` are still accepted.
    def tool_paths=(value)
      array_of_strings = value.is_a?(Array) && value.all? { |s| s.is_a?(String) }
      raise ArgumentError, "tool_paths must be an Array of Strings; got #{value.inspect}" unless array_of_strings

      value.each do |entry|
        next unless TOOL_PATHS_BLOCKLIST.include?(_normalize_tool_path_entry(entry))

        raise ArgumentError,
              "tool_paths entry #{entry.inspect} is too broad: it resolves to a root-like directory " \
              "(app/actions, app, or the project root) that would auto-expose every business action as a " \
              "tool. Use a dedicated narrow subdir such as `agent_tools` or `actions/tools`."
      end

      @tool_paths = value
    end

    # Leading namespace segments stripped when deriving a tool's `tool_name` from its
    # class name. Cosmetic and broad (may safely include `actions`). Global by default,
    # per-class overridable (a class can narrow/replace the set it derives against).
    setting :tool_name_stripped_prefixes,
            default: %w[actions tools agent_tools],
            overridable: true,
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| s.is_a?(String) } }

    attr_writer :logger, :env, :on_exception, :rails

    # Optional callable returning a Hash of ambient context data (e.g. from request-local state).
    # Consulted when no explicit `ambient_context:` kwarg is passed to an Axn call. Falls back to
    # `Axn::Core::AmbientContext.default_source` when nil.
    attr_accessor :ambient_context_provider

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

      # Build the dedicated Sidekiq default worker now (at boot, in every process) so it exists
      # and carries the default's config/block when a globally-defaulted action is enqueued or run.
      return unless @default_async_adapter == :sidekiq && defined?(Axn::Async::Adapters::Sidekiq)

      Axn::Async::Adapters::Sidekiq.configure_default_worker!(config: @default_async_config, block: @default_async_config_block)
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
      Axn::Internal::Callable.call_with_desired_shape(@on_exception, args: [e], kwargs: { action:, context: })
    end

    def logger
      return @logger if @logger

      # Use sidekiq logger if in background
      resolved =
        begin
          if Axn::Util::ExecutionContext.background? && defined?(Sidekiq)
            Sidekiq.logger
          else
            Rails.logger
          end
        rescue NameError
          nil
        end

      # Memoize a real host logger, but not the stdout fallback below: `Rails.logger` is nil
      # until Rails runs its initialize_logger initializer, so `include Axn` at gem load (under
      # Bundler.require) resolves to nil here. Returning the transient fallback without caching it
      # keeps every `Axn.config.logger.<level>` call site working during boot and still picks up
      # `Rails.logger` on a later call once it exists (PRO-2891).
      return @logger = resolved if resolved

      @fallback_logger ||= Logger.new($stdout).tap { |l| l.level = Logger::INFO }
    end

    def env
      @env ||= ENV["RACK_ENV"].presence || ENV["RAILS_ENV"].presence || "development"
      ActiveSupport::StringInquirer.new(@env)
    end

    private

    # Normalizes a tool_paths entry for the broad-entry blocklist check: strips surrounding
    # whitespace and any leading/trailing slashes, so `" /actions/ "` and `"actions"` compare equal.
    def _normalize_tool_path_entry(entry)
      entry.to_s.strip.gsub(%r{\A/+|/+\z}, "")
    end

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
