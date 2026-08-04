# frozen_string_literal: true

require "axn/error"
require "axn/internal/registry"

module Axn
  # Deliberately NOT descended from the registry's internal base classes: a public class must not put
  # an Axn::Internal constant in its ancestry, and "any registry lookup miss" is `rescue Axn::Error`.
  class StrategyNotFound < StandardError
    include Axn::Error
  end

  class DuplicateStrategyError < StandardError
    include Axn::Error
  end

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
