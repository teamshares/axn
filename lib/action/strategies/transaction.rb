# frozen_string_literal: true

module Action
  module Strategies
    module Transaction
      extend ActiveSupport::Concern

      included do
        puts "Transaction strategy included!"
        # TODO: implement
      end
    end
  end
end
