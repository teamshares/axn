# frozen_string_literal: true

module Axn
  module Enqueueable
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
          job_class = Class.new(ActiveJob::Base)

          # Give the job class a meaningful name for logging and debugging
          job_name = "#{name}::ActiveJobProxy"
          const_set("ActiveJobProxy", job_class)
          job_class.define_singleton_method(:name) { job_name }

          # Define the perform method
          job_class.define_method(:perform) do |job_context = {}|
            self.class.call!(**job_context)
          end

          # Apply the async configuration block if it exists
          job_class.class_eval(&_async_config) if _async_config

          job_class
        end
      end
    end
  end
end
