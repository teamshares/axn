# frozen_string_literal: true

require "axn/async/batch_enqueue/config"

module Axn
  module Async
    # BatchEnqueue provides declarative batch enqueueing for Axn actions.
    #
    # Use `enqueue_each` to specify which fields to iterate over when batch enqueueing.
    # This creates `enqueue_all` and `enqueue_all_async` methods on your action class.
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
        class_attribute :_batch_enqueue_configs, default: nil
      end

      # DSL methods for batch enqueueing
      module DSL
        # Declare a field to iterate over for batch enqueueing
        #
        # @param field [Symbol] The field name from expects to iterate over
        # @param from [Proc, Symbol, nil] The source collection (lambda, method name, or inferred from model)
        # @param via [Symbol, nil] Optional attribute to extract from each item (e.g., :id)
        # @param block [Proc, nil] Optional filter block - return truthy to enqueue, falsy to skip
        def enqueue_each(field, from: nil, via: nil, &filter_block)
          # Initialize configs array if needed
          self._batch_enqueue_configs ||= []

          # Add this field's config
          config = Config.new(field:, from:, via:, filter_block:)
          self._batch_enqueue_configs += [config]

          # Mount the enqueue_all action on first enqueue_each call
          _mount_batch_enqueue_action_if_needed
        end

        private

        def _mount_batch_enqueue_action_if_needed
          # Only mount once - check if we already have the descriptor
          return if _mounted_axn_descriptors.any? { |d| d.name == "enqueue_all" }

          # Use mountable infrastructure to create the action class
          # This gives us inheritance profiles, namespace management, etc.
          Axn::Mountable::Helpers::Mounter.mount_via_strategy(
            target: self,
            as: :enqueue_all,
            name: "enqueue_all",
            axn_klass: nil,
            inherit: :async_only,
          ) { nil } # Placeholder - real call method defined by the strategy
        end
      end
    end
  end
end
