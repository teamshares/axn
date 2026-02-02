# frozen_string_literal: true

# Defines the behavioral contracts that all async adapters must satisfy.
# These contracts are used as documentation and to generate shared examples
# for testing adapter implementations.
#
# Each adapter (Sidekiq, ActiveJob, future adapters) must implement these
# behaviors identically to ensure consistent async execution semantics.
module AsyncAdapterContracts
  # Exception handling contracts
  # All adapters must handle exceptions consistently
  EXCEPTION_HANDLING = {
    fail_does_not_retry: {
      description: "Axn::Failure (from fail!) does not trigger retries or on_exception",
      rationale: "fail! is a deliberate business decision, not a transient error",
    },
    exception_causes_retry: {
      description: "Unexpected exceptions are re-raised for the background framework to retry",
      rationale: "Transient errors should be retried by the job framework",
    },
    exception_triggers_on_exception: {
      description: "Unexpected exceptions trigger on_exception hooks",
      rationale: "Errors should be reported to monitoring systems",
    },
  }.freeze

  # Retry context contracts
  # All adapters must provide consistent retry context information
  RETRY_CONTEXT = {
    includes_adapter: {
      description: "Retry context includes adapter name (:sidekiq, :active_job, etc.)",
    },
    includes_attempt: {
      description: "Retry context includes current attempt number (1-indexed)",
    },
    includes_max_retries: {
      description: "Retry context includes maximum retry count",
    },
    includes_job_id: {
      description: "Retry context includes job identifier when available",
    },
    includes_first_attempt: {
      description: "Retry context includes first_attempt? boolean",
    },
    includes_retries_exhausted: {
      description: "Retry context includes retries_exhausted? boolean",
    },
    available_in_on_exception: {
      description: "Retry context is available in on_exception callback via context[:async]",
    },
  }.freeze

  # async_exception_reporting mode contracts
  # All adapters must respect the global and per-class exception reporting modes
  EXCEPTION_REPORTING_MODES = {
    every_attempt: {
      description: "Reports on every retry attempt",
      first_attempt_reports: true,
      intermediate_attempt_reports: true,
      exhaustion_reports: true,
    },
    first_and_exhausted: {
      description: "Reports on first attempt and when retries exhausted",
      first_attempt_reports: true,
      intermediate_attempt_reports: false,
      exhaustion_reports: true,
    },
    only_exhausted: {
      description: "Reports only when retries are exhausted",
      first_attempt_reports: false,
      intermediate_attempt_reports: false,
      exhaustion_reports: true,
    },
  }.freeze

  # Per-class override contracts
  # All adapters must respect per-class async_exception_reporting overrides
  PER_CLASS_OVERRIDE = {
    overrides_global_config: {
      description: "Per-class async_exception_reporting overrides global Axn.config setting",
    },
    nil_falls_back_to_global: {
      description: "When per-class setting is nil, falls back to global config",
    },
    inherited_by_subclasses: {
      description: "Child classes inherit parent's async_exception_reporting setting",
    },
    subclass_can_override: {
      description: "Child classes can override parent's async_exception_reporting setting",
    },
  }.freeze

  # Delayed execution contracts
  # All adapters must support the _async options for delayed execution
  DELAYED_EXECUTION = {
    wait_delays_execution: {
      description: "_async: { wait: N } delays execution by N seconds",
    },
    wait_until_schedules_execution: {
      description: "_async: { wait_until: Time } schedules execution at specific time",
    },
    non_hash_passes_through: {
      description: "Non-hash _async values pass through as regular kwargs",
    },
    empty_hash_ignored: {
      description: "Empty _async hash is ignored (immediate execution)",
    },
  }.freeze

  # Exhaustion handling contracts
  # All adapters must trigger on_exception when retries are exhausted
  EXHAUSTION_HANDLING = {
    triggers_on_exception: {
      description: "Death handler / after_discard triggers on_exception",
    },
    respects_reporting_mode: {
      description: "Exhaustion handler respects async_exception_reporting mode",
    },
    respects_per_class_override: {
      description: "Exhaustion handler respects per-class async_exception_reporting override",
    },
    includes_exhaustion_context: {
      description: "Exhaustion report includes retries_exhausted: true in context",
    },
  }.freeze

  # Helper to get all contract categories
  def self.all_categories
    {
      exception_handling: EXCEPTION_HANDLING,
      retry_context: RETRY_CONTEXT,
      exception_reporting_modes: EXCEPTION_REPORTING_MODES,
      per_class_override: PER_CLASS_OVERRIDE,
      delayed_execution: DELAYED_EXECUTION,
      exhaustion_handling: EXHAUSTION_HANDLING,
    }
  end

  # Helper to list all contracts for documentation
  def self.all_contracts
    all_categories.flat_map do |category, contracts|
      contracts.map do |name, details|
        {
          category:,
          name:,
          description: details[:description],
        }
      end
    end
  end
end
