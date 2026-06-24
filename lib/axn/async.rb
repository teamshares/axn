# frozen_string_literal: true

require "axn/async/adapters"
require "axn/async/batch_enqueue"
require "axn/async/retry_context"

module Axn
  module Async
    extend ActiveSupport::Concern

    included do
      class_attribute :_async_adapter, :_async_config, :_async_config_block, default: nil
      # True when the adapter was applied via the global default (call_async/worker hook)
      # rather than an explicit `async ...` in the action body. The Sidekiq adapter uses this
      # to decide between a per-action Worker subclass (explicit: reconstructable in a worker)
      # and the shared generic Worker (global default: no per-action body to reconstruct).
      class_attribute :_async_via_default, default: false
      class_attribute :_async_exception_reporting, default: nil

      # Include batch enqueue functionality
      include BatchEnqueue
      extend BatchEnqueue::DSL
    end

    class_methods do
      # Sets the exception reporting mode for this action class, overriding the global config.
      # This allows library authors to configure exception reporting behavior for their actions
      # without affecting the host app's global Axn.config.async_exception_reporting setting.
      #
      # @param mode [Symbol, nil] One of :every_attempt, :first_and_exhausted, or :only_exhausted.
      #   Use nil to clear the per-class override and fall back to the global config.
      # @raise [ArgumentError] if mode is not a valid option
      #
      # @example
      #   class SlackSender::Base
      #     include Axn
      #     async_exception_reporting :only_exhausted
      #   end
      def async_exception_reporting(mode)
        if mode.nil?
          self._async_exception_reporting = nil
          return
        end

        unless Axn::Configuration::ASYNC_EXCEPTION_REPORTING_OPTIONS.include?(mode)
          raise ArgumentError,
                "async_exception_reporting must be one of: #{Axn::Configuration::ASYNC_EXCEPTION_REPORTING_OPTIONS.join(', ')}"
        end

        self._async_exception_reporting = mode
      end

      # `via_default: true` is set only by the default-application paths (call_async /
      # _ensure_default_async_configured). An explicit `async :sidekiq` from a class body — even
      # on a subclass that inherited `_async_via_default = true` — passes false and clears the
      # marker, so the Sidekiq adapter builds/uses the per-action worker (honoring explicit config)
      # rather than the shared DefaultWorker.
      def async(adapter = nil, via_default: false, **config, &block)
        self._async_adapter = adapter
        self._async_config = config
        self._async_config_block = block
        self._async_via_default = via_default

        case adapter
        when false
          include Adapters.find(:disabled)
        when nil
          # Use default configuration, but preserve any user-provided block/config
          merged_config = Axn.config._default_async_config.merge(config)
          merged_block = block || Axn.config._default_async_config_block
          async Axn.config._default_async_adapter, **merged_config, &merged_block
        else
          # Look up adapter in registry
          adapter_module = Adapters.find(adapter)
          include adapter_module
          # Per-action setup that must run on EVERY `async <adapter>` declaration — including a
          # subclass re-declaring it, where `include` is a no-op (module already inherited) so the
          # adapter's `included do` won't fire. The Sidekiq adapter uses this to (re)build the
          # action's per-action Worker subclass with the current config.
          adapter_module._configure_action!(self) if adapter_module.respond_to?(:_configure_action!)
        end
      end

      def call_async(**kwargs)
        # Set up default async configuration if none is set
        if _async_adapter.nil?
          async Axn.config._default_async_adapter, via_default: true, **Axn.config._default_async_config, &Axn.config._default_async_config_block
          # Call ourselves again now that the adapter is included
          return call_async(**kwargs)
        end

        # Skip notification and logging for disabled adapter (it will raise immediately)
        return _enqueue_async_job(kwargs) if _async_adapter == false

        # Emit notification for async call
        _emit_call_async_notification(kwargs)

        # Log async invocation if logging is enabled
        adapter_name = _async_adapter_name_for_logging
        _log_async_invocation(kwargs, adapter_name:) if adapter_name && log_calls_level

        # Delegate to adapter-specific enqueueing logic
        _enqueue_async_job(kwargs)
      end

      # Ensure default async is applied when the class is first instantiated
      # This is important for Sidekiq workers which load the class in a separate process
      def new(*args, **kwargs)
        _ensure_default_async_configured
        super
      end

      private

      def _emit_call_async_notification(kwargs)
        resource = name || "AnonymousClass"
        # Use dup to ensure kwargs modifications don't affect the notification payload
        payload = { resource:, action_class: self, kwargs: kwargs.dup, adapter: _async_adapter_name }

        ActiveSupport::Notifications.instrument("axn.call_async", payload)
      rescue StandardError => e
        # Don't raise in notification emission to avoid interfering with async enqueueing
        Axn::Internal::PipingError.swallow("emitting notification for axn.call_async", action_class: self, exception: e)
      end

      def _log_async_invocation(kwargs, adapter_name:)
        Axn::Internal::CallLogger.log_at_level(
          self,
          level: log_calls_level,
          message_parts: ["Enqueueing async execution via #{adapter_name}"],
          join_string: " with: ",
          before: _async_log_separator,
          prefix: "[#{name.presence || 'Anonymous Class'}]",
          error_context: "logging async invocation",
          context_direction: :inbound,
          context_data: kwargs,
        )
      end

      def _async_log_separator
        return if Axn.config.env.production?
        return if Axn::Util::ExecutionContext.background?
        return if Axn::Util::ExecutionContext.console?

        "\n------\n"
      end

      # Hook method that must be implemented by async adapter modules.
      #
      # Adapters MUST:
      # - Implement this method with adapter-specific enqueueing logic
      # - NOT override `call_async` (the base implementation handles notifications, logging, and delegates here)
      #
      # The only exception is the Disabled adapter, which overrides `call_async` to raise immediately
      # without emitting notifications.
      #
      # @param kwargs [Hash] The keyword arguments to pass to the action when it executes
      # @return The result of enqueueing (typically a job ID or similar, adapter-specific)
      def _enqueue_async_job(kwargs)
        # This will be overridden by the included adapter module
        raise NotImplementedError, "No async adapter configured. Use e.g. `async :sidekiq` or `async :active_job` to enable background processing."
      end

      def _async_adapter_name
        if _async_adapter.nil?
          "none"
        elsif _async_adapter == false
          "disabled"
        else
          _async_adapter.to_s
        end
      end

      def _async_adapter_name_for_logging
        return nil if _async_adapter.nil? || _async_adapter == false

        _async_adapter_name
      end

      def _ensure_default_async_configured
        # Only when the adapter is genuinely unset — an explicit `async false` (disabled) must be
        # left intact so callers (e.g. enqueue_all validation) reject it upfront rather than
        # silently defaulting it (false.present? is falsy, so guard on nil explicitly).
        return unless _async_adapter.nil?
        return unless Axn.config._default_async_adapter.present?

        async Axn.config._default_async_adapter, via_default: true, **Axn.config._default_async_config, &Axn.config._default_async_config_block
      end

      # Extracts and normalizes _async options from kwargs.
      # Returns normalized options hash (with string keys and converted durations) and removes _async from kwargs.
      #
      # @param kwargs [Hash] The keyword arguments (modified in place)
      # @return [Hash, nil] Normalized async options hash, or nil if no _async options present
      def _extract_and_normalize_async_options(kwargs)
        async_options = kwargs.delete(:_async) if kwargs[:_async].is_a?(Hash)
        _normalize_async_options(async_options) if async_options
      end

      # Normalizes _async options hash:
      # - Converts symbol keys to string keys
      # - Converts ActiveSupport::Duration values to integer seconds (for wait)
      # - Preserves Time objects (for wait_until)
      #
      # @param async_hash [Hash, nil] The async options hash
      # @return [Hash, nil] Normalized hash with string keys, or nil if input is not a hash
      def _normalize_async_options(async_hash)
        return nil unless async_hash.is_a?(Hash)

        normalized = {}
        async_hash.each do |key, value|
          string_key = key.to_s

          normalized[string_key] = case string_key
                                   when "wait"
                                     # Convert ActiveSupport::Duration to integer seconds
                                     value.respond_to?(:to_i) ? value.to_i : value
                                   else
                                     # Preserve wait_until and other keys/values as-is
                                     value
                                   end
        end

        normalized
      end
    end
  end
end
