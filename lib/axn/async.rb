# frozen_string_literal: true

require "axn/async/adapters"

module Axn
  module Async
    extend ActiveSupport::Concern

    included do
      class_attribute :_async_adapter, :_async_config, :_async_config_block, default: nil
    end

    class_methods do
      def async(adapter = nil, **config, &block)
        self._async_adapter = adapter
        self._async_config = config
        self._async_config_block = block

        case adapter
        when false
          include Adapters.find(:disabled)
        when nil
          # Use default configuration
          async Axn.config._default_async_adapter, **Axn.config._default_async_config, &Axn.config._default_async_config_block
        else
          # Look up adapter in registry
          adapter_module = Adapters.find(adapter)
          include adapter_module
        end
      end

      def call_async(**kwargs)
        # Set up default async configuration if none is set
        if _async_adapter.nil?
          async Axn.config._default_async_adapter, **Axn.config._default_async_config, &Axn.config._default_async_config_block
          # Call ourselves again now that the adapter is included
          return call_async(**kwargs)
        end

        # This will be overridden by the included adapter module
        raise NotImplementedError, "No async adapter configured. Use e.g. `async :sidekiq` or `async :active_job` to enable background processing."
      end

      # Ensure default async is applied when the class is first instantiated
      # This is important for Sidekiq workers which load the class in a separate process
      def new(*args, **kwargs)
        _ensure_default_async_configured
        super
      end

      private

      def _log_async_invocation(kwargs, adapter_name:)
        Axn::Util::Logging.log_at_level(
          self,
          level: log_calls_level,
          message_parts: ["Enqueueing async execution via #{adapter_name}"],
          join_string: " with: ",
          before: Axn.config.env.production? ? nil : "\n------\n",
          error_context: "logging async invocation",
          context_direction: :inbound,
          context_data: kwargs,
        )
      end

      def _ensure_default_async_configured
        return if _async_adapter.present?
        return unless Axn.config._default_async_adapter.present?

        async Axn.config._default_async_adapter, **Axn.config._default_async_config, &Axn.config._default_async_config_block
      end
    end
  end
end
