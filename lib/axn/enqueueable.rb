# frozen_string_literal: true

require "axn/enqueueable/via_sidekiq"
require "axn/enqueueable/via_activejob"
require "axn/enqueueable/disabled"

module Axn
  module Enqueueable
    extend ActiveSupport::Concern

    included do
      class_attribute :_async_adapter, :_async_config, default: nil
    end

    class_methods do
      def async(adapter = nil, &block)
        self._async_adapter = adapter
        self._async_config = block

        case adapter
        when false
          include Disabled
        when :sidekiq
          raise LoadError, "Sidekiq is not available. Please add 'sidekiq' to your Gemfile." unless defined?(Sidekiq)

          include ViaSidekiq
          class_eval(&block) if block_given?
        when :active_job
          raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(ActiveJob)

          include ViaActiveJob
          class_eval(&block) if block_given?
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
