# frozen_string_literal: true

module Axn
  module Enqueueable
    # I am *NOT* happy with this kludge of an implementation, but ActiveJob *only* supports
    # inheritance so we need to dynamically create a job class that inherits from ActiveJob::Base.
    # This implementation does NOT support callbacks or more complex configurations, but it does get
    # basic functionality working.
    module ViaActiveJob
      extend ActiveSupport::Concern

      included do
        raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(ActiveJob)

        class_attribute :_activejob_configs, default: []

        # Apply the async configuration block if it exists
        class_eval(&_async_config) if _async_config
      end

      class_methods do
        def call_async(context = {})
          # Create a job class that inherits from ActiveJob::Base
          job_class = Class.new(ActiveJob::Base) do
            define_method(:perform) do |job_context = {}|
              self.class.call!(**job_context)
            end
          end

          # Give the job class a meaningful name for logging and debugging
          job_name = "#{name}::ActiveJobProxy"
          # Register the class with a proper name in the original class's namespace
          const_set("ActiveJobProxy", job_class)
          # Set the name directly on the class for better logging
          job_class.define_singleton_method(:name) { job_name }

          # Apply stored configurations to the job class
          _activejob_configs.each do |method, args|
            case method
            when :set
              job_class.set(args)
            when :queue_as
              job_class.queue_as(args)
            when :retry_on
              job_class.retry_on(args[:exception], **args.reject { |k, v| k == :exception || v.nil? })
            when :discard_on
              job_class.discard_on(args)
            when :priority=
              job_class.priority = args
            end
          end

          job_class.perform_later(context)
        end

        def call(context = {})
          # This should delegate to the parent class's call method
          super(**context)
        end

        # Intercept ActiveJob configuration methods
        def set(options = {})
          self._activejob_configs += [[:set, options]]
        end

        def queue_as(queue_name)
          self._activejob_configs += [[:queue_as, queue_name]]
        end

        def retry_on(exception, wait: nil, attempts: nil, queue: nil, priority: nil, jitter: nil)
          self._activejob_configs += [[:retry_on, { exception:, wait:, attempts:, queue:, priority:, jitter: }]]
        end

        def discard_on(exception)
          self._activejob_configs += [[:discard_on, exception]]
        end

        def priority=(priority)
          self._activejob_configs += [[:priority=, priority]]
        end
      end
    end
  end
end
