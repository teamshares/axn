# frozen_string_literal: true

require "axn/async/batch_enqueue/config"

module Axn
  module Async
    # BatchEnqueue provides declarative batch enqueueing for Axn actions.
    #
    # Fields with `model:` declarations are automatically inferred for iteration.
    # Use `enqueues_each` to override defaults, add filtering, or iterate non-model fields.
    # All Axn classes have `enqueue_all` defined, which validates configuration and
    # executes iteration asynchronously via EnqueueAllTrigger.
    #
    # @example Auto-inference from model: (no enqueues_each needed)
    #   class SyncCompany
    #     include Axn
    #     async :sidekiq
    #
    #     expects :company, model: Company  # Auto-inferred: Company.all
    #
    #     def call
    #       # sync logic
    #     end
    #   end
    #
    #   SyncCompany.enqueue_all  # Automatically iterates Company.all
    #
    # @example With explicit source override
    #   enqueues_each :company, from: -> { Company.active }
    #
    # @example With extraction (passes company_id instead of company object)
    #   enqueues_each :company_id, from: -> { Company.active }, via: :id
    #
    # @example With filter block
    #   enqueues_each :company do |company|
    #     company.active? && !company.in_exit?
    #   end
    #
    # @example Override on enqueue_all call
    #   # Override with enumerable (replaces source)
    #   SyncCompany.enqueue_all(company: Company.active.limit(10))
    #
    #   # Override with scalar (makes it static, no iteration)
    #   SyncCompany.enqueue_all(company: Company.find(123))
    #
    # @example Multi-field cross-product
    #   enqueues_each :user, from: -> { User.active }
    #   enqueues_each :company, from: -> { Company.active }
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
        # Fields with `model:` declarations are automatically inferred for iteration.
        # You can override iteration by passing enumerables (to replace source) or
        # scalars (to make fields static) as kwargs.
        #
        # @param static_args [Hash] Arguments to pass to every enqueued job.
        #   - Scalar values: Treated as static args (passed to all jobs)
        #   - Enumerable values: Treated as iteration sources (overrides configured sources)
        #   - Exception: Arrays/Sets are static when field expects enumerable type
        # @return [String] Job ID from the async adapter
        # @raise [NotImplementedError] If async is not configured
        # @raise [MissingEnqueuesEachError] If expects exist but no iteration config found
        # @raise [ArgumentError] If required static fields are missing
        def enqueue_all(**static_args)
          EnqueueAllTrigger.enqueue_for(self, **static_args)
        end

        # Declare a field to iterate over for batch enqueueing.
        #
        # Note: Fields with `model:` declarations are automatically inferred, so
        # `enqueues_each` is only needed to override defaults, add filtering, or
        # iterate non-model fields.
        #
        # @param field [Symbol] The field name from expects to iterate over
        # @param from [Proc, Symbol, nil] The source collection.
        #   - Proc/lambda: Called to get the collection
        #   - Symbol: Method name on the action class
        #   - nil: Inferred from field's `model:` declaration (Model.all)
        # @param via [Symbol, nil] Optional attribute to extract from each item (e.g., :id)
        # @param block [Proc, nil] Optional filter block - return truthy to enqueue, falsy to skip
        def enqueues_each(field, from: nil, via: nil, &filter_block)
          self._batch_enqueue_configs += [Config.new(field:, from:, via:, filter_block:)]
        end
      end
    end
  end
end
