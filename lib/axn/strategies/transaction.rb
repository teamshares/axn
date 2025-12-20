# frozen_string_literal: true

module Axn
  class Strategies
    module Transaction
      extend ActiveSupport::Concern

      included do
        raise NotImplementedError, "Transaction strategy requires ActiveRecord" unless defined?(ActiveRecord)

        around do |hooked|
          early_completion = nil
          ActiveRecord::Base.transaction do
            hooked.call
          rescue Axn::Internal::EarlyCompletion => e
            # EarlyCompletion is not an error - it's a control flow mechanism
            # Store it to re-raise after transaction commits
            early_completion = e
          end
          # Re-raise EarlyCompletion after transaction commits successfully
          raise early_completion if early_completion
        end
      end
    end
  end
end
