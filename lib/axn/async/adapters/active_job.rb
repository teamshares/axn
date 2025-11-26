# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module ActiveJob
        extend ActiveSupport::Concern

        included do
          raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(::ActiveJob::Base)

          # Validate that kwargs are not provided for ActiveJob
          if _async_config&.any?
            raise ArgumentError, "ActiveJob adapter requires a configuration block. Use `async :active_job do ... end` instead of passing keyword arguments."
          end
        end

        class_methods do
          private

          # Implements adapter-specific enqueueing logic for ActiveJob.
          # Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
          def _enqueue_async_job(kwargs)
            job = active_job_proxy_class

            if kwargs[:_async].is_a?(Hash)
              options = kwargs.delete(:_async)
              if options[:wait_until]
                job = job.set(wait_until: options[:wait_until])
              elsif options[:wait]
                job = job.set(wait: options[:wait])
              end
            end

            job.perform_later(**kwargs)
          end

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
              proxy.class_eval(&_async_config_block) if _async_config_block

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
