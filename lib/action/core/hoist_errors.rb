# frozen_string_literal: true

module Action
  module HoistErrors
    def self.included(base)
      base.class_eval do
        include InstanceMethods
      end
    end

    module InstanceMethods
      private

      MinimalFailedResult = Data.define(:error, :exception) do
        def ok? = false
      end

      # This method is used to ensure that the result of a block is successful before proceeding.
      #
      # Assumes success unless the block raises an exception or returns a failed result.
      # (i.e. if you wrap logic that is NOT an action call, it'll be successful unless it raises an exception)
      def hoist_errors(prefix: nil)
        raise ArgumentError, "#hoist_errors must be given a block to execute" unless block_given?

        result = begin
          yield
        rescue StandardError => e
          log "hoist_errors block transforming a #{e.class.name} exception: #{e.message}"
          MinimalFailedResult.new(error: nil, exception: e)
        end

        # This ensures the last line of hoist_errors was an Action call
        #
        # CAUTION: if there are multiple calls per block, only the last one will be checked!
        #
        unless result.respond_to?(:ok?)
          raise ArgumentError,
                "#hoist_errors is expected to wrap an Action call, but it returned a #{result.class.name} instead"
        end

        return result if result.ok?

        _handle_hoisted_errors(result, prefix:)
      end

      # Separate method to allow overriding in subclasses
      def _handle_hoisted_errors(result, prefix: nil)
        @context.exception = result.exception if result.exception.present?
        @context.error_prefix = prefix if prefix.present?

        # TODO: do we maybe want to always use exception.message? :thinking:
        error = result.exception.is_a?(Action::Failure) ? result.exception.message : result.error
        fail! error
      end
    end
  end
end
