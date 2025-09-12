# frozen_string_literal: true

require "axn/async/adapters"

module Axn
  module Async
    extend ActiveSupport::Concern

    included do
      class_attribute :_async_adapter, :_async_config, default: nil
      # TODO: some initial application
      # async
    end

    class_methods do
      def async(adapter = nil, &block)
        self._async_adapter = adapter
        self._async_config = block

        case adapter
        when false
          include Adapters.find(:disabled)
        when nil
          # Use default configuration
          async Axn.config.default_async
        else
          # Look up adapter in registry
          adapter_module = Adapters.find(adapter)
          include adapter_module
        end
      end

      def call_async(context = {})
        # Set up default async configuration if none is set
        async Axn.config.default_async if _async_adapter.nil?

        # This will be overridden by the included adapter module
        raise NotImplementedError, "No async adapter configured. Use e.g. `async :sidekiq` or `async :active_job` to enable background processing."
      end
    end
  end
end
