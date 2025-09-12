# frozen_string_literal: true

require "axn/async/via_sidekiq"
require "axn/async/via_activejob"
require "axn/async/disabled"

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
          include Disabled
        when :sidekiq
          include ViaSidekiq
        when :active_job
          include ViaActiveJob
        when nil
          # Use default configuration
          async Axn.config.default_async
        else
          raise ArgumentError, "Unsupported async adapter: #{adapter}. Supported adapters are: :sidekiq, :active_job, false"
        end
      end

      def call_async(context = {})
        # Set up default async configuration if none is set
        async Axn.config.default_async if _async_adapter.nil?

        # This will be overridden by the included adapter module
        raise NotImplementedError, "No async adapter configured. Use `async :sidekiq` or `async :active_job` to enable background processing."
      end
    end
  end
end
