# frozen_string_literal: true

module Axn
  class Strategies
    module Transaction
      extend ActiveSupport::Concern

      included do
        raise NotImplementedError, "Transaction strategy requires ActiveRecord" unless defined?(ActiveRecord)

        around do |hooked|
          ActiveRecord::Base.transaction do
            hooked.call
          end
        end
      end
    end
  end
end
