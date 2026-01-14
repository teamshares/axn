# frozen_string_literal: true

require "axn/async/batch_enqueue/config"

module Axn
  module Async
    # BatchEnqueue provides declarative batch enqueueing for Axn actions.
    #
    # Use `enqueue_each` to specify which fields to iterate over when batch enqueueing.
    # All Axn classes have `enqueue_all` defined, which validates configuration and
    # executes iteration asynchronously via EnqueueAllTrigger.
    #
    # @example Simple iteration with model inference
    #   class SyncCompany
    #     include Axn
    #     async :sidekiq
    #
    #     expects :company, model: Company
    #
    #     def call
    #       # sync logic
    #     end
    #
    #     enqueue_each :company  # iterates Company.all
    #   end
    #
    #   SyncCompany.enqueue_all  # enqueues a job for each company
    #
    # @example With explicit source
    #   enqueue_each :company, from: -> { Company.active }
    #
    # @example With extraction (passes company_id instead of company object)
    #   enqueue_each :company_id, from: -> { Company.active }, via: :id
    #
    # @example With filter block
    #   enqueue_each :company do |company|
    #     company.active? && !company.in_exit?
    #   end
    #
    # @example Multi-field cross-product
    #   enqueue_each :user, from: -> { User.active }
    #   enqueue_each :company, from: -> { Company.active }
    #   # Produces user_count × company_count jobs
    module BatchEnqueue
      extend ActiveSupport::Concern

      included do
        class_attribute :_batch_enqueue_configs, default: []
      end

      # DSL methods for batch enqueueing
      module DSL
        # Batch enqueue jobs for this action.
        #
        # Validates async is configured, validates static args, then executes
        # iteration asynchronously via EnqueueAllTrigger.
        #
        # @param static_args [Hash] Arguments to pass to every enqueued job
        # @return [String] Job ID from the async adapter
        # @raise [NotImplementedError] If async is not configured
        # @raise [MissingEnqueueEachError] If expects exist but no enqueue_each configured
        # @raise [ArgumentError] If required static fields are missing
        def enqueue_all(**static_args)
          EnqueueAllTrigger.enqueue_for(self, **static_args)
        end

        # Declare a field to iterate over for batch enqueueing
        #
        # @param field [Symbol] The field name from expects to iterate over
        # @param from [Proc, Symbol, nil] The source collection (lambda, method name, or inferred from model)
        # @param via [Symbol, nil] Optional attribute to extract from each item (e.g., :id)
        # @param block [Proc, nil] Optional filter block - return truthy to enqueue, falsy to skip
        def enqueue_each(field, from: nil, via: nil, &filter_block)
          self._batch_enqueue_configs += [Config.new(field:, from:, via:, filter_block:)]
        end
      end
    end
  end
end
