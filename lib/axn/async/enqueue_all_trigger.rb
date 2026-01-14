# frozen_string_literal: true

module Axn
  module Async
    # Shared trigger action for executing enqueue_all in the background.
    # Used by enqueue_all_async to defer batch iteration to a background job.
    #
    # Configure the async adapter via Axn.config.set_enqueue_all_async,
    # or it defaults to Axn.config.set_default_async.
    #
    # @example Configure a specific queue for all enqueue_all_async jobs
    #   Axn.configure do |c|
    #     c.set_enqueue_all_async(:sidekiq, queue: :batch)
    #   end
    class EnqueueAllTrigger
      include Axn

      expects :target_class_name
      expects :static_args, default: {}, allow_blank: true

      def call
        target = target_class_name.constantize
        target.enqueue_all(**static_args.symbolize_keys)
      end

      class << self
        # Override to use enqueue_all-specific async config
        def call_async(...)
          _ensure_enqueue_all_async_configured
          super
        end

        private

        def _ensure_enqueue_all_async_configured
          return if _async_adapter.present?
          return unless Axn.config._enqueue_all_async_adapter.present?

          async(
            Axn.config._enqueue_all_async_adapter,
            **Axn.config._enqueue_all_async_config,
            &Axn.config._enqueue_all_async_config_block
          )
        end
      end
    end
  end
end
