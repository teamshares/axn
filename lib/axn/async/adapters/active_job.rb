# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module ActiveJob
        extend ActiveSupport::Concern

        included do
          raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(::ActiveJob::Base)
        end

        class_methods do
          def call_async(context = {})
            active_job_proxy_class.perform_later(context || {})
          end

          private

          def active_job_proxy_class
            @active_job_proxy_class ||= create_active_job_proxy_class
          end

          def create_active_job_proxy_class
            # Store reference to the original action class
            action_class = self

            # Create the ActiveJob proxy class
            Class.new(::ActiveJob::Base).tap do |proxy|
              # Give the job class a meaningful name for logging and debugging
              job_name = "#{name}::ActiveJobProxy"
              const_set("ActiveJobProxy", proxy)
              proxy.define_singleton_method(:name) { job_name }

              # Apply the async configuration block if it exists
              proxy.class_eval(&_async_config) if _async_config

              # Define the perform method
              proxy.define_method(:perform) do |job_context = {}|
                # Call the original action class with the job context
                action_class.call!(**job_context)
              end
            end
          end
        end
      end
    end
  end
end
