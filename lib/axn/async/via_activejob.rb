# frozen_string_literal: true

module Axn
  module Async
    module ViaActiveJob
      extend ActiveSupport::Concern

      included do
        raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(ActiveJob)
      end

      class_methods do
        def call_async(context = {})
          active_job_proxy_class.perform_later(context)
        end

        private

        def active_job_proxy_class
          @active_job_proxy_class ||= create_active_job_proxy_class
        end

        def create_active_job_proxy_class
          # Create the ActiveJob proxy class
          Class.new(ActiveJob::Base).tap do |proxy|
            # Give the job class a meaningful name for logging and debugging
            job_name = "#{name}::ActiveJobProxy"
            const_set("ActiveJobProxy", proxy)
            proxy.define_singleton_method(:name) { job_name }

            # Apply the async configuration block if it exists
            proxy.class_eval(&_async_config) if _async_config

            # Define the perform method
            proxy.define_method(:perform) do |job_context = {}|
              self.class.call!(**job_context)
            end
          end
        end
      end
    end
  end
end
