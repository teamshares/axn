# frozen_string_literal: true

module Axn
  module Internal
    # Transitional delegator: the guard now lives at Axn::Extensions.best_effort.
    # Remaining internal call sites migrate to the block form; this module is deleted afterward.
    module PipingError
      def self.swallow(desc, exception:, action: nil)
        Axn::Extensions.best_effort(desc, action:) { raise exception }
      end
    end
  end
end
