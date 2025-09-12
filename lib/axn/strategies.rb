# frozen_string_literal: true

require "axn/internal/registry"

module Axn
  class StrategyNotFound < Axn::Internal::Registry::NotFound; end
  class DuplicateStrategyError < Axn::Internal::Registry::DuplicateError; end

  class Strategies < Axn::Internal::Registry
    class << self
      def registry_directory = __dir__

      private

      def item_type = "Strategy"
      def not_found_error_class = StrategyNotFound
      def duplicate_error_class = DuplicateStrategyError
    end
  end
end
